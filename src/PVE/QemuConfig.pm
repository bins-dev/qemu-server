package PVE::QemuConfig;

use strict;
use warnings;

use Scalar::Util qw(blessed);

use PVE::AbstractConfig;
use PVE::INotify;
use PVE::JSONSchema;
use PVE::QemuMigrate::Helpers;
use PVE::QemuServer::Agent;
use PVE::QemuServer::Blockdev;
use PVE::QemuServer::CPUConfig;
use PVE::QemuServer::Drive;
use PVE::QemuServer::Helpers;
use PVE::QemuServer::Monitor qw(mon_cmd);
use PVE::QemuServer;
use PVE::QemuServer::Machine;
use PVE::QemuServer::Memory qw(get_current_memory);
use PVE::RESTEnvironment qw(log_warn);
use PVE::Storage;
use PVE::Tools;
use PVE::Format qw(render_bytes render_duration);

use base qw(PVE::AbstractConfig);

my $nodename = PVE::INotify::nodename();

mkdir "/etc/pve/nodes/$nodename";
mkdir "/etc/pve/nodes/$nodename/qemu-server";

my $lock_dir = "/var/lock/qemu-server";
mkdir $lock_dir;

sub assert_config_exists_on_node {
    my ($vmid, $node) = @_;

    $node //= $nodename;

    my $filename = __PACKAGE__->config_file($vmid, $node);
    my $exists = -f $filename;

    my $type = guest_type();
    die "unable to find configuration file for $type $vmid on node '$node'\n"
        if !$exists;
}

# BEGIN implemented abstract methods from PVE::AbstractConfig

sub guest_type {
    return "VM";
}

sub __config_max_unused_disks {
    my ($class) = @_;

    return $PVE::QemuServer::Drive::MAX_UNUSED_DISKS;
}

sub config_file_lock {
    my ($class, $vmid) = @_;

    return "$lock_dir/lock-$vmid.conf";
}

sub cfs_config_path {
    my ($class, $vmid, $node) = @_;

    $node = $nodename if !$node;
    return "nodes/$node/qemu-server/$vmid.conf";
}

sub has_feature {
    my ($class, $feature, $conf, $storecfg, $snapname, $running, $backup_only) = @_;

    my $err;
    $class->foreach_volume(
        $conf,
        sub {
            my ($ds, $drive) = @_;

            return if PVE::QemuServer::drive_is_cdrom($drive);
            return if $backup_only && defined($drive->{backup}) && !$drive->{backup};
            my $volid = $drive->{file};
            $err = 1
                if !PVE::Storage::volume_has_feature($storecfg, $feature, $volid, $snapname,
                    $running);
        },
    );

    return $err ? 0 : 1;
}

sub valid_volume_keys {
    my ($class, $reverse) = @_;

    my @keys = PVE::QemuServer::Drive::valid_drive_names();

    return $reverse ? reverse @keys : @keys;
}

# FIXME: adapt parse_drive to use $noerr for better error messages
sub parse_volume {
    my ($class, $key, $volume_string, $noerr) = @_;

    my $volume;
    if ($key eq 'vmstate') {
        eval { PVE::JSONSchema::check_format('pve-volume-id', $volume_string) };
        if (my $err = $@) {
            return if $noerr;
            die $err;
        }
        $volume = { 'file' => $volume_string };
    } else {
        $volume = PVE::QemuServer::Drive::parse_drive($key, $volume_string);
    }

    die "unable to parse volume\n" if !defined($volume) && !$noerr;

    return $volume;
}

sub print_volume {
    my ($class, $key, $volume) = @_;

    return PVE::QemuServer::Drive::print_drive($volume);
}

sub volid_key {
    my ($class) = @_;

    return 'file';
}

sub get_replicatable_volumes {
    my ($class, $storecfg, $vmid, $conf, $cleanup, $noerr) = @_;

    my $volhash = {};

    my $test_volid = sub {
        my ($volid, $attr) = @_;

        return if $attr->{cdrom};

        return if !$cleanup && !$attr->{replicate};

        if ($volid =~ m|^/|) {
            return if !$attr->{replicate};
            return if $cleanup || $noerr;
            die "unable to replicate local file/device '$volid'\n";
        }

        my ($storeid, $volname) = PVE::Storage::parse_volume_id($volid, $noerr);
        return if !$storeid;

        my $scfg = PVE::Storage::storage_config($storecfg, $storeid);
        return if $scfg->{shared};

        my ($path, $owner, $vtype) = PVE::Storage::path($storecfg, $volid);
        return if !$owner || ($owner != $vmid);

        if ($vtype ne 'images') {
            return if $cleanup || $noerr;
            die "unable to replicate volume '$volid', type '$vtype'\n";
        }

        if (!PVE::Storage::volume_has_feature($storecfg, 'replicate', $volid)) {
            return if $cleanup || $noerr;
            die "missing replicate feature on volume '$volid'\n";
        }

        $volhash->{$volid} = 1;
    };

    PVE::QemuServer::foreach_volid($conf, $test_volid);

    return $volhash;
}

sub get_backup_volumes {
    my ($class, $conf) = @_;

    my $return_volumes = [];

    my $test_volume = sub {
        my ($key, $drive) = @_;

        return if PVE::QemuServer::drive_is_cdrom($drive);

        my $included = $drive->{backup} // 1;
        my $reason = "backup=";
        $reason .= defined($drive->{backup}) ? 'no' : 'yes';

        if ($key =~ m/^efidisk/ && (!defined($conf->{bios}) || $conf->{bios} ne 'ovmf')) {
            $included = 0;
            $reason = "efidisk but no OMVF BIOS";
        }

        push @$return_volumes,
            {
                key => $key,
                included => $included,
                reason => $reason,
                volume_config => $drive,
            };
    };

    PVE::QemuConfig->foreach_volume($conf, $test_volume);

    return $return_volumes;
}

sub __snapshot_assert_no_blockers {
    my ($class, $vmconf, $save_vmstate) = @_;
    PVE::QemuMigrate::Helpers::check_non_migratable_resources($vmconf, $save_vmstate, 0);
}

sub __snapshot_save_vmstate {
    my ($class, $vmid, $conf, $snapname, $storecfg, $statestorage, $suspend) = @_;

    # use given storage or search for one from the config
    my $target = $statestorage;

    if (!$target) {
        $target = find_vmstate_storage($conf, $storecfg);
    }

    my $mem_size = get_current_memory($conf->{memory});
    my $driver_state_size = 500; # assume 500MB is enough to safe all driver state;
    # our savevm-start does live-save of the memory until the space left in the
    # volume is just enough for the remaining memory content + internal state
    # then it stops the vm and copies the rest so we reserve twice the
    # memory content + state to minimize vm downtime
    my $size = $mem_size * 2 + $driver_state_size;
    my $scfg = PVE::Storage::storage_config($storecfg, $target);

    my $name = "vm-$vmid-state-$snapname";
    $name .= ".raw" if $scfg->{path}; # add filename extension for file base storage

    my $statefile =
        PVE::Storage::vdisk_alloc($storecfg, $target, $vmid, 'raw', $name, $size * 1024);
    my $runningmachine = PVE::QemuServer::Machine::get_current_qemu_machine($vmid);

    # get current QEMU -cpu argument to ensure consistency of custom CPU models
    my $runningcpu;
    if (my $pid = PVE::QemuServer::check_running($vmid)) {
        $runningcpu = PVE::QemuServer::CPUConfig::get_cpu_from_running_vm($pid);
    }

    if (!$suspend) {
        $conf = $conf->{snapshots}->{$snapname};
    }

    $conf->{vmstate} = $statefile;
    $conf->{runningmachine} = $runningmachine;
    $conf->{runningcpu} = $runningcpu;

    return $statefile;
}

sub __snapshot_activate_storages {
    my ($class, $conf, $include_vmstate) = @_;

    my $storecfg = PVE::Storage::config();
    my $opts = $include_vmstate ? { 'extra_keys' => ['vmstate'] } : {};
    my $storage_hash = {};

    $class->foreach_volume_full(
        $conf,
        $opts,
        sub {
            my ($key, $drive) = @_;

            return if PVE::QemuServer::drive_is_cdrom($drive);

            my ($storeid) = PVE::Storage::parse_volume_id($drive->{file});
            $storage_hash->{$storeid} = 1;
        },
    );

    PVE::Storage::activate_storage_list($storecfg, [sort keys $storage_hash->%*]);
}

sub __snapshot_check_running {
    my ($class, $vmid) = @_;
    return PVE::QemuServer::Helpers::vm_running_locally($vmid);
}

sub __snapshot_check_freeze_needed {
    my ($class, $vmid, $config, $save_vmstate) = @_;

    my $running = $class->__snapshot_check_running($vmid);
    if (!$save_vmstate) {
        return (
            $running,
            $running
                && PVE::QemuServer::parse_guest_agent($config)->{enabled}
                && PVE::QemuServer::Agent::qga_check_running($vmid),
        );
    } else {
        return ($running, 0);
    }
}

sub __snapshot_freeze {
    my ($class, $vmid, $unfreeze) = @_;

    if ($unfreeze) {
        eval { mon_cmd($vmid, "guest-fsfreeze-thaw"); };
        warn "guest-fsfreeze-thaw problems - $@" if $@;
    } else {
        eval { mon_cmd($vmid, "guest-fsfreeze-freeze"); };
        warn "guest-fsfreeze-freeze problems - $@" if $@;
    }
}

sub __snapshot_create_vol_snapshots_hook {
    my ($class, $vmid, $snap, $running, $hook) = @_;

    if ($running) {
        my $storecfg = PVE::Storage::config();

        if ($hook eq "before") {
            if ($snap->{vmstate}) {
                my $path = PVE::Storage::path($storecfg, $snap->{vmstate});
                PVE::Storage::activate_volumes($storecfg, [$snap->{vmstate}]);
                my $state_storage_id = PVE::Storage::parse_volume_id($snap->{vmstate});

                PVE::QemuMigrate::Helpers::set_migration_caps($vmid, 1);
                mon_cmd($vmid, "savevm-start", statefile => $path);
                print "saving VM state and RAM using storage '$state_storage_id'\n";
                my $render_state = sub {
                    my ($stat) = @_;
                    my $b = render_bytes($stat->{bytes});
                    my $t = render_duration($stat->{'total-time'} / 1000);
                    return ($b, $t);
                };
                my $round = 0;
                for (;;) {
                    $round++;
                    my $stat = mon_cmd($vmid, "query-savevm");
                    if (!$stat->{status}) {
                        die "savevm not active\n";
                    } elsif ($stat->{status} eq 'active') {
                        if ($round < 60 || $round % 10 == 0) {
                            my ($b, $t) = $render_state->($stat);
                            print "$b in $t\n";
                        }
                        print "reducing reporting rate to every 10s\n" if $round == 60;
                        sleep(1);
                        next;
                    } elsif ($stat->{status} eq 'completed') {
                        my ($b, $t) = $render_state->($stat);
                        print "completed saving the VM state in $t, saved $b\n";
                        last;
                    } elsif ($stat->{status} eq 'failed') {
                        my $err = $stat->{error} || 'unknown error';
                        die "unable to save VM state and RAM - $err\n";
                    } else {
                        die "query-savevm returned unexpected status '$stat->{status}'\n";
                    }
                }
            } else {
                mon_cmd($vmid, "savevm-start");
            }
        } elsif ($hook eq "after") {
            eval {
                mon_cmd($vmid, "savevm-end");
                PVE::Storage::deactivate_volumes($storecfg, [$snap->{vmstate}])
                    if $snap->{vmstate};
            };
            warn $@ if $@;
        } elsif ($hook eq "after-freeze") {
            # savevm-end is async, we need to wait
            for (;;) {
                my $stat = mon_cmd($vmid, "query-savevm");
                if (!$stat->{bytes}) {
                    last;
                } else {
                    print "savevm not yet finished\n";
                    sleep(1);
                    next;
                }
            }
        }
    }
}

sub __snapshot_create_vol_snapshot {
    my ($class, $vmid, $ds, $drive, $snapname) = @_;

    return if PVE::QemuServer::drive_is_cdrom($drive);

    my $volid = $drive->{file};
    my $device = "drive-$ds";
    my $storecfg = PVE::Storage::config();

    print "snapshotting '$device' ($drive->{file})\n";

    PVE::QemuServer::qemu_volume_snapshot($vmid, $device, $storecfg, $drive, $snapname);
}

sub __snapshot_delete_remove_drive {
    my ($class, $snap, $remove_drive) = @_;

    if ($remove_drive eq 'vmstate') {
        delete $snap->{$remove_drive};
    } else {
        my $drive = PVE::QemuServer::parse_drive($remove_drive, $snap->{$remove_drive});
        return if PVE::QemuServer::drive_is_cdrom($drive);

        my $volid = $drive->{file};
        delete $snap->{$remove_drive};
        $class->add_unused_volume($snap, $volid);
    }
}

sub __snapshot_delete_vmstate_file {
    my ($class, $snap, $force) = @_;

    my $storecfg = PVE::Storage::config();

    eval { PVE::Storage::vdisk_free($storecfg, $snap->{vmstate}); };
    if (my $err = $@) {
        die $err if !$force;
        warn $err;
    }
}

sub __snapshot_delete_vol_snapshot {
    my ($class, $vmid, $ds, $drive, $snapname, $unused) = @_;

    return if PVE::QemuServer::drive_is_cdrom($drive);
    my $storecfg = PVE::Storage::config();
    my $volid = $drive->{file};

    PVE::QemuServer::qemu_volume_snapshot_delete($vmid, $storecfg, $drive, $snapname);

    push @$unused, $volid;
}

sub __snapshot_rollback_hook {
    my ($class, $vmid, $conf, $snap, $prepare, $data) = @_;

    if ($prepare) {
        # we save the machine of the current config
        $data->{oldmachine} = $conf->{machine};
    } else {
        # if we have a 'runningmachine' entry in the snapshot we use that
        # for the forcemachine parameter, else we use the old logic
        if (defined($conf->{runningmachine})) {
            $data->{forcemachine} = $conf->{runningmachine};
            delete $conf->{runningmachine};

            # runningcpu is newer than runningmachine, so assume it only exists
            # here, if at all
            $data->{forcecpu} = delete $conf->{runningcpu}
                if defined($conf->{runningcpu});
        } else {
            # Note: old code did not store 'machine', so we try to be smart
            # and guess the snapshot was generated with kvm 1.4 (pc-i440fx-1.4).
            my $machine_conf = PVE::QemuServer::Machine::parse_machine($conf->{machine});
            $data->{forcemachine} = $machine_conf->{type} || 'pc-i440fx-1.4';

            # we remove the 'machine' configuration if not explicitly specified
            # in the original config.
            delete $conf->{machine} if $snap->{vmstate} && !defined($data->{oldmachine});
        }

        if ($conf->{vmgenid}) {
            # tell the VM that it's another generation, so it can react
            # appropriately, e.g. dirty-mark copies of distributed databases or
            # re-initializing its random number generator
            $conf->{vmgenid} = PVE::QemuServer::generate_uuid();
        }
    }

    return;
}

sub __snapshot_rollback_vol_possible {
    my ($class, $drive, $snapname, $blockers) = @_;

    return if PVE::QemuServer::drive_is_cdrom($drive);

    my $storecfg = PVE::Storage::config();
    my $volid = $drive->{file};

    PVE::Storage::volume_rollback_is_possible($storecfg, $volid, $snapname, $blockers);
}

sub __snapshot_rollback_vol_rollback {
    my ($class, $drive, $snapname) = @_;

    return if PVE::QemuServer::drive_is_cdrom($drive);

    my $storecfg = PVE::Storage::config();
    PVE::Storage::volume_snapshot_rollback($storecfg, $drive->{file}, $snapname);
}

sub __snapshot_rollback_vm_stop {
    my ($class, $vmid) = @_;

    my $storecfg = PVE::Storage::config();
    PVE::QemuServer::vm_stop($storecfg, $vmid, undef, undef, 5, undef, undef);
}

sub __snapshot_rollback_vm_start {
    my ($class, $vmid, $vmstate, $data) = @_;

    my $storecfg = PVE::Storage::config();
    my $params = {
        statefile => $vmstate,
        forcemachine => $data->{forcemachine},
        forcecpu => $data->{forcecpu},
    };
    PVE::QemuServer::vm_start($storecfg, $vmid, $params);
}

sub __snapshot_rollback_get_unused {
    my ($class, $conf, $snap) = @_;

    my $unused = [];

    $class->foreach_volume(
        $conf,
        sub {
            my ($vs, $volume) = @_;

            return if PVE::QemuServer::drive_is_cdrom($volume, 1);

            my $found = 0;
            my $volid = $volume->{file};

            $class->foreach_volume(
                $snap,
                sub {
                    my ($ds, $drive) = @_;

                    return if $found;
                    return if PVE::QemuServer::drive_is_cdrom($drive, 1);

                    $found = 1
                        if ($drive->{file} && $drive->{file} eq $volid);
                },
            );

            push @$unused, $volid if !$found;
        },
    );

    return $unused;
}

sub add_unused_volume {
    my ($class, $config, $volid) = @_;

    if ($volid =~ m/vm-\d+-cloudinit/) {
        print "found unused cloudinit disk '$volid', removing it\n";
        my $storecfg = PVE::Storage::config();
        PVE::Storage::vdisk_free($storecfg, $volid);
        return undef;
    } else {
        return $class->SUPER::add_unused_volume($config, $volid);
    }
}

sub load_current_config {
    my ($class, $vmid, $current) = @_;

    my $conf = $class->SUPER::load_current_config($vmid, $current);
    delete $conf->{'special-sections'};
    return $conf;
}

sub get_derived_property {
    my ($class, $conf, $name) = @_;

    my $defaults = PVE::QemuServer::load_defaults();

    if ($name eq 'max-cpu') {
        my $cpus =
            ($conf->{sockets} || $defaults->{sockets}) * ($conf->{cores} || $defaults->{cores});
        return $conf->{vcpus} || $cpus;
    } elsif ($name eq 'max-memory') { # current usage maximum, not maximum hotpluggable
        return get_current_memory($conf->{memory}) * 1024 * 1024;
    } else {
        die "unknown derived property - $name\n";
    }
}

sub write_config {
    my ($class, $vmid, $conf) = @_;

    # Dispatch to class the object was blessed with if caller invoked the method via the
    # 'PVE::QemuConfig' class name explicitly. This is hack, but the code currently doesn't
    # generally use blessed config objects. Safeguard against infinite recursion.
    if (blessed($conf) && !blessed($class)) {
        return $conf->write_config($vmid, $conf);
    }

    return $class->SUPER::write_config($vmid, $conf);
}

# END implemented abstract methods from PVE::AbstractConfig

sub has_cloudinit {
    my ($class, $conf, $skip) = @_;

    my $found;

    $class->foreach_volume(
        $conf,
        sub {
            my ($key, $volume) = @_;

            return if ($skip && $skip eq $key) || $found;
            $found = $key if PVE::QemuServer::Drive::drive_is_cloudinit($volume);
        },
    );

    return $found;
}

# Caller is expected to deal with volumes from an already existing 'fleecing' special section in the
# configuration first.
sub record_fleecing_images {
    my ($vmid, $volids) = @_;

    return if scalar($volids->@*) == 0;

    PVE::QemuConfig->lock_config(
        $vmid,
        sub {
            my $conf = PVE::QemuConfig->load_config($vmid);
            $conf->{'special-sections'}->{fleecing}->{'fleecing-images'} =
                join(',', $volids->@*);
            PVE::QemuConfig->write_config($vmid, $conf);
        },
    );
}

# Will also cancel a running backup job inside QEMU. Not doing so can lead to a deadlock when
# attempting to detach the fleecing image.
sub cleanup_fleecing_images {
    my ($vmid, $storecfg, $log_func) = @_;

    if (!$log_func) {
        $log_func = sub {
            my ($level, $line) = @_;
            chomp($line);
            if ($level eq 'info') {
                print "$line\n";
            } else {
                log_warn($line);
            }
        };
    }

    my $volids = [];
    my $failed = [];

    # cancel left-over backup job and detach any left-over images from a running VM
    if (PVE::QemuServer::Helpers::vm_running_locally($vmid)) {
        eval {
            if (my $status = mon_cmd($vmid, 'query-backup')) {
                if ($status->{status} && $status->{status} eq 'active') {
                    $log_func->(
                        'warn',
                        "left-over backup job still running inside QEMU - canceling now",
                    );
                    mon_cmd($vmid, 'backup-cancel');
                }
            }
        };
        $log_func->('warn', "checking/canceling old backup job failed - $@") if $@;

        PVE::QemuServer::Blockdev::detach_fleecing_block_nodes($vmid, $log_func);
    }

    PVE::QemuConfig->lock_config(
        $vmid,
        sub {
            my $conf = PVE::QemuConfig->load_config($vmid);
            my $special = $conf->{'special-sections'};
            if (my $fleecing = $special->{fleecing}) {
                $volids = [PVE::Tools::split_list($fleecing->{'fleecing-images'})];
                delete $fleecing->{'fleecing-images'};
                delete $special->{fleecing} if !scalar(keys $fleecing->%*);
                PVE::QemuConfig->write_config($vmid, $conf);
            }
        },
    );

    for my $volid ($volids->@*) {
        $log_func->('info', "removing (old) fleecing image '$volid'");
        eval { PVE::Storage::vdisk_free($storecfg, $volid); };
        if (my $err = $@) {
            $log_func->('warn', "error removing fleecing image '$volid' - $err");
            push $failed->@*, $volid;
        }
    }

    record_fleecing_images($vmid, $failed);
}

sub foreach_storage_used_by_vm {
    my ($conf, $func) = @_;

    my $sidhash = {};

    PVE::QemuConfig->foreach_volume(
        $conf,
        sub {
            my ($ds, $drive) = @_;
            return if PVE::QemuServer::Drive::drive_is_cdrom($drive);

            my $volid = $drive->{file};

            my ($sid, $volname) = PVE::Storage::parse_volume_id($volid, 1);
            $sidhash->{$sid} = $sid if $sid;
        },
    );

    foreach my $sid (sort keys %$sidhash) {
        &$func($sid);
    }
}

# NOTE: if this logic changes, please update docs & possibly gui logic
sub find_vmstate_storage {
    my ($conf, $storecfg) = @_;

    # first, return storage from conf if set
    return $conf->{vmstatestorage} if $conf->{vmstatestorage};

    my ($target, $shared, $local);

    foreach_storage_used_by_vm(
        $conf,
        sub {
            my ($sid) = @_;
            my $scfg = PVE::Storage::storage_config($storecfg, $sid);
            my $dst = $scfg->{shared} ? \$shared : \$local;
            $$dst = $sid if !$$dst || $scfg->{path}; # prefer file based storage
        },
    );

    # second, use shared storage where VM has at least one disk
    # third, use local storage where VM has at least one disk
    # fall back to local storage
    $target = $shared // $local // 'local';

    return $target;
}

1;
