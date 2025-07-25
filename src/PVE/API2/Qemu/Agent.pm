package PVE::API2::Qemu::Agent;

use strict;
use warnings;

use PVE::RESTHandler;
use PVE::JSONSchema qw(get_standard_option);
use PVE::QemuServer;
use PVE::QemuServer::Agent qw(agent_cmd check_agent_error);
use PVE::QemuServer::Monitor qw(mon_cmd);
use MIME::Base64 qw(encode_base64 decode_base64);
use JSON;

use base qw(PVE::RESTHandler);

# max size for file-read over the api
my $MAX_READ_SIZE = 16 * 1024 * 1024; # 16 MiB

# list of commands
# will generate one api endpoint per command
# needs a 'method' property and a 'perms' property
my $guest_agent_commands = {
    'ping' => {
        method => 'POST',
        perms => 'VM.GuestAgent.Audit',
    },
    'get-time' => {
        method => 'GET',
        perms => 'VM.GuestAgent.Audit',
    },
    'info' => {
        method => 'GET',
        perms => 'VM.GuestAgent.Audit',
    },
    'fsfreeze-status' => {
        method => 'POST',
        perms => {
            check => [
                'perm',
                '/vms/{vmid}',
                [
                    'VM.GuestAgent.Audit',
                    'VM.GuestAgent.FileSystemMgmt',
                    'VM.GuestAgent.Unrestricted',
                ],
                any => 1,
            ],
        },
    },
    'fsfreeze-freeze' => {
        method => 'POST',
        perms => 'VM.GuestAgent.FileSystemMgmt',
    },
    'fsfreeze-thaw' => {
        method => 'POST',
        perms => 'VM.GuestAgent.FileSystemMgmt',
    },
    'fstrim' => {
        method => 'POST',
        perms => 'VM.GuestAgent.FileSystemMgmt',
    },
    'network-get-interfaces' => {
        method => 'GET',
        perms => 'VM.GuestAgent.Audit',
    },
    'get-vcpus' => {
        method => 'GET',
        perms => 'VM.GuestAgent.Audit',
    },
    'get-fsinfo' => {
        method => 'GET',
        perms => 'VM.GuestAgent.Audit',
    },
    'get-memory-blocks' => {
        method => 'GET',
        perms => 'VM.GuestAgent.Audit',
    },
    'get-memory-block-info' => {
        method => 'GET',
        perms => 'VM.GuestAgent.Audit',
    },
    'suspend-hybrid' => {
        method => 'POST',
        perms => 'VM.PowerMgmt',
    },
    'suspend-ram' => {
        method => 'POST',
        perms => 'VM.PowerMgmt',
    },
    'suspend-disk' => {
        method => 'POST',
        perms => 'VM.PowerMgmt',
    },
    'shutdown' => {
        method => 'POST',
        perms => 'VM.PowerMgmt',
    },
    # added since qemu 2.9
    'get-host-name' => {
        method => 'GET',
        perms => 'VM.GuestAgent.Audit',
    },
    'get-osinfo' => {
        method => 'GET',
        perms => 'VM.GuestAgent.Audit',
    },
    'get-users' => {
        method => 'GET',
        perms => 'VM.GuestAgent.Audit',
    },
    'get-timezone' => {
        method => 'GET',
        perms => 'VM.GuestAgent.Audit',
    },
};

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    proxyto => 'node',
    method => 'GET',
    description => "QEMU Guest Agent command index.",
    permissions => {
        user => 'all',
    },
    parameters => {
        additionalProperties => 1,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option(
                'pve-vmid',
                { completion => \&PVE::QemuServer::complete_vmid_running },
            ),
        },
    },
    returns => {
        type => 'array',
        items => {
            type => "object",
            properties => {},
        },
        links => [{ rel => 'child', href => '{name}' }],
        description => "Returns the list of QEMU Guest Agent commands",
    },
    code => sub {
        my ($param) = @_;

        my $result = [];

        my $cmds = [keys %$guest_agent_commands];
        push @$cmds, qw(
            exec
            exec-status
            file-read
            file-write
            set-user-password
        );

        for my $cmd (sort @$cmds) {
            push @$result, { name => $cmd };
        }

        return $result;
    },
});

sub register_command {
    my ($class, $command, $method, $perm) = @_;

    die "no method given\n" if !$method;
    die "no command given\n" if !defined($command);

    my $permission;

    if (ref($perm) eq 'HASH') {
        $permission = $perm;
    } else {
        die "internal error: missing permission for $command" if !$perm;

        $permission = {
            check => ['perm', '/vms/{vmid}', [$perm, 'VM.GuestAgent.Unrestricted'], any => 1],
        };
    }

    my $parameters = {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option(
                'pve-vmid',
                {
                    completion => \&PVE::QemuServer::complete_vmid_running,
                },
            ),
            command => {
                type => 'string',
                description => "The QGA command.",
                enum => [sort keys %$guest_agent_commands],
            },
        },
    };

    my $description = "Execute QEMU Guest Agent commands.";
    my $name = 'agent';

    if ($command ne '') {
        $description = "Execute $command.";
        $name = $command;
        delete $parameters->{properties}->{command};
    }

    __PACKAGE__->register_method({
        name => $name,
        path => $command,
        method => $method,
        protected => 1,
        proxyto => 'node',
        description => $description,
        permissions => $permission,
        parameters => $parameters,
        returns => {
            type => 'object',
            description => "Returns an object with a single `result` property.",
        },
        code => sub {
            my ($param) = @_;

            my $vmid = $param->{vmid};

            my $conf = PVE::QemuConfig->load_config($vmid); # check if VM exists

            PVE::QemuServer::Agent::assert_agent_available($vmid, $conf);

            my $cmd = $param->{command} // $command;
            my $res = mon_cmd($vmid, "guest-$cmd");

            return { result => $res };
        },
    });
}

# old {vmid}/agent POST endpoint, here for compatibility
__PACKAGE__->register_command('', 'POST', 'VM.GuestAgent.Unrestricted');

for my $cmd (sort keys %$guest_agent_commands) {
    my $props = $guest_agent_commands->{$cmd};
    __PACKAGE__->register_command($cmd, $props->{method}, $props->{perms});
}

# commands with parameters are complicated and we want to register them manually
__PACKAGE__->register_method({
    name => 'set-user-password',
    path => 'set-user-password',
    method => 'POST',
    protected => 1,
    proxyto => 'node',
    description => "Sets the password for the given user to the given password",
    permissions => { check => ['perm', '/vms/{vmid}', ['VM.GuestAgent.Unrestricted']] },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option(
                'pve-vmid',
                { completion => \&PVE::QemuServer::complete_vmid_running },
            ),
            username => {
                type => 'string',
                description => 'The user to set the password for.',
            },
            password => {
                type => 'string',
                description => 'The new password.',
                minLength => 5,
                maxLength => 1024,
            },
            crypted => {
                type => 'boolean',
                description =>
                    'set to 1 if the password has already been passed through crypt()',
                optional => 1,
                default => 0,
            },
        },
    },
    returns => {
        type => 'object',
        description => "Returns an object with a single `result` property.",
    },
    code => sub {
        my ($param) = @_;

        my $vmid = $param->{vmid};
        my $conf = PVE::QemuConfig->load_config($vmid);

        my $crypted = $param->{crypted} // 0;
        my $args = {
            username => $param->{username},
            password => encode_base64($param->{password}),
            crypted => $crypted ? JSON::true : JSON::false,
        };
        my $res =
            agent_cmd($vmid, $conf, "set-user-password", $args, 'cannot set user password');

        return { result => $res };
    },
});

__PACKAGE__->register_method({
    name => 'exec',
    path => 'exec',
    method => 'POST',
    protected => 1,
    proxyto => 'node',
    description =>
        "Executes the given command in the vm via the guest-agent and returns an object with the pid.",
    permissions => { check => ['perm', '/vms/{vmid}', ['VM.GuestAgent.Unrestricted']] },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option(
                'pve-vmid',
                { completion => \&PVE::QemuServer::complete_vmid_running },
            ),
            command => {
                type => 'array',
                description => 'The command as a list of program + arguments.',
                items => {
                    format => 'string',
                    description => 'A single part of the program + arguments.',
                },
            },
            'input-data' => {
                type => 'string',
                maxLength => 64 * 1024,
                description =>
                    "Data to pass as 'input-data' to the guest. Usually treated as STDIN to 'command'.",
                optional => 1,
            },
        },
    },
    returns => {
        type => 'object',
        properties => {
            pid => {
                type => 'integer',
                description => "The PID of the process started by the guest-agent.",
            },
        },
    },
    code => sub {
        my ($param) = @_;

        my $vmid = $param->{vmid};
        my $conf = PVE::QemuConfig->load_config($vmid);

        my $cmd = $param->{command};

        my $res = PVE::QemuServer::Agent::qemu_exec($vmid, $conf, $param->{'input-data'}, $cmd);
        return $res;
    },
});

__PACKAGE__->register_method({
    name => 'exec-status',
    path => 'exec-status',
    method => 'GET',
    protected => 1,
    proxyto => 'node',
    description => "Gets the status of the given pid started by the guest-agent",
    permissions => { check => ['perm', '/vms/{vmid}', ['VM.GuestAgent.Unrestricted']] },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option(
                'pve-vmid',
                { completion => \&PVE::QemuServer::complete_vmid_running },
            ),
            pid => {
                type => 'integer',
                description => 'The PID to query',
            },
        },
    },
    returns => {
        type => 'object',
        properties => {
            exited => {
                type => 'boolean',
                description => 'Tells if the given command has exited yet.',
            },
            exitcode => {
                type => 'integer',
                optional => 1,
                description => 'process exit code if it was normally terminated.',
            },
            signal => {
                type => 'integer',
                optional => 1,
                description =>
                    'signal number or exception code if the process was abnormally terminated.',
            },
            'out-data' => {
                type => 'string',
                optional => 1,
                description => 'stdout of the process',
            },
            'err-data' => {
                type => 'string',
                optional => 1,
                description => 'stderr of the process',
            },
            'out-truncated' => {
                type => 'boolean',
                optional => 1,
                description => 'true if stdout was not fully captured',
            },
            'err-truncated' => {
                type => 'boolean',
                optional => 1,
                description => 'true if stderr was not fully captured',
            },
        },
    },
    code => sub {
        my ($param) = @_;

        my $vmid = $param->{vmid};
        my $conf = PVE::QemuConfig->load_config($vmid);

        my $pid = int($param->{pid});

        my $res = PVE::QemuServer::Agent::qemu_exec_status($vmid, $conf, $pid);

        return $res;
    },
});

__PACKAGE__->register_method({
    name => 'file-read',
    path => 'file-read',
    method => 'GET',
    protected => 1,
    proxyto => 'node',
    description => "Reads the given file via guest agent. Is limited to $MAX_READ_SIZE bytes.",
    permissions => {
        check => [
            'perm',
            '/vms/{vmid}',
            ['VM.GuestAgent.FileRead', 'VM.GuestAgent.Unrestricted'],
            any => 1,
        ],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option(
                'pve-vmid',
                { completion => \&PVE::QemuServer::complete_vmid_running },
            ),
            file => {
                type => 'string',
                description => 'The path to the file',
            },
        },
    },
    returns => {
        type => 'object',
        description => "Returns an object with a `content` property.",
        properties => {
            content => {
                type => 'string',
                description => "The content of the file, maximum $MAX_READ_SIZE",
            },
            truncated => {
                type => 'boolean',
                optional => 1,
                description => "If set to 1, the output is truncated and not complete",
            },
        },
    },
    code => sub {
        my ($param) = @_;

        my $vmid = $param->{vmid};
        my $conf = PVE::QemuConfig->load_config($vmid);

        my $qgafh =
            agent_cmd($vmid, $conf, "file-open", { path => $param->{file} }, "can't open file");

        my $bytes_left = $MAX_READ_SIZE;
        my $eof = 0;
        my $read_size = 1024 * 1024;
        my $content = "";

        while ($bytes_left > 0 && !$eof) {
            my $read =
                mon_cmd($vmid, "guest-file-read", handle => $qgafh, count => int($read_size));
            check_agent_error($read, "can't read from file");

            $content .= decode_base64($read->{'buf-b64'});
            $bytes_left -= $read->{count};
            $eof = $read->{eof} // 0;
        }

        my $res = mon_cmd($vmid, "guest-file-close", handle => $qgafh);
        check_agent_error($res, "can't close file", 1);

        my $result = {
            content => $content,
            'bytes-read' => ($MAX_READ_SIZE - $bytes_left),
        };

        if (!$eof) {
            warn
                "agent file-read: reached maximum read size: $MAX_READ_SIZE bytes. output might be truncated.\n";
            $result->{truncated} = 1;
        }

        return $result;
    },
});

__PACKAGE__->register_method({
    name => 'file-write',
    path => 'file-write',
    method => 'POST',
    protected => 1,
    proxyto => 'node',
    description => "Writes the given file via guest agent.",
    permissions => {
        check => [
            'perm',
            '/vms/{vmid}',
            ['VM.GuestAgent.FileWrite', 'VM.GuestAgent.Unrestricted'],
            any => 1,
        ],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option(
                'pve-vmid',
                { completion => \&PVE::QemuServer::complete_vmid_running },
            ),
            file => {
                type => 'string',
                description => 'The path to the file.',
            },
            content => {
                type => 'string',
                maxLength => 60 * 1024, # 60k, smaller than our 64k POST limit
                description => "The content to write into the file.",
            },
            encode => {
                type => 'boolean',
                description =>
                    "If set, the content will be encoded as base64 (required by QEMU)."
                    . "Otherwise the content needs to be encoded beforehand - defaults to true.",
                optional => 1,
                default => 1,
            },
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        my $vmid = $param->{vmid};
        my $conf = PVE::QemuConfig->load_config($vmid);

        my $buf =
            ($param->{encode} // 1) ? encode_base64($param->{content}) : $param->{content};

        my $qgafh = agent_cmd(
            $vmid,
            $conf,
            "file-open",
            { path => $param->{file}, mode => 'wb' },
            "can't open file",
        );

        agent_cmd(
            $vmid,
            $conf,
            "file-write",
            { handle => $qgafh, 'buf-b64' => $buf },
            "can't write to file",
        );

        agent_cmd($vmid, $conf, "file-close", { handle => $qgafh }, "can't close file");

        return;
    },
});

1;
