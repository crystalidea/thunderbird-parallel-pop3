#!/usr/bin/env perl
#
# Patch a Thunderbird installation to check POP3 accounts in parallel.
#
# Replaces three JavaScript modules inside omni.ja. Every entry is verified by
# SHA-256 against the exact bytes the patch was built from, so the script
# refuses to touch an installation it does not recognise. The original omni.ja
# is backed up first.
#
# Once patched the behaviour is unconditional; there is nothing to switch on.
#
#   perl patch-parallel-pop3.pl --install DIR [--profile DIR] [options]
#
#   --install DIR   Thunderbird installation directory. On macOS this may be
#                   either Thunderbird.app or its Contents/Resources.
#   --profile DIR   Profile directory. Its startupCache is deleted, without
#                   which the patched modules are ignored in favour of cached
#                   bytecode.
#   --payload DIR   Directory holding manifest.json and payload/. Defaults to
#                   the directory this script lives in.
#   --restore       Put the backed up omni.ja back and exit.
#   --dry-run       Verify everything and report, but write nothing.
#   --force         Continue when the installed version differs from the one
#                   the payload was built for. The per-entry SHA-256 checks
#                   still apply and cannot be bypassed.
#   --help          This text.

use strict;
use warnings;

use File::Basename qw(basename dirname);
use File::Copy qw(copy);
use File::Path qw(remove_tree);
use File::Spec;
use Getopt::Long qw(GetOptions);

# Core since 5.10 / 5.14 respectively.
use Digest::SHA qw(sha256_hex);
use JSON::PP;

my %opt = (payload => dirname(File::Spec->rel2abs($0)));
GetOptions(
    \%opt,
    'install=s', 'profile=s', 'payload=s',
    'restore', 'dry-run', 'force', 'help',
) or usage(1);

usage(0) if $opt{help};
usage(1) unless $opt{install};

my $DRY = $opt{'dry-run'};

# Archive::Zip is the one non-core dependency. Bail out with instructions
# rather than a bare "Can't locate" from the interpreter.
unless (eval { require Archive::Zip; Archive::Zip->import(qw(:ERROR_CODES :CONSTANTS)); 1 }) {
    print STDERR <<'MISSING';
Archive::Zip is required but not installed for this perl.

  Debian/Ubuntu   sudo apt install libarchive-zip-perl
  Fedora/RHEL     sudo dnf install perl-Archive-Zip
  Arch            sudo pacman -S perl-archive-zip
  macOS/any       cpan Archive::Zip
  Windows         Strawberry Perl ships with it; ActivePerl: ppm install Archive-Zip

MISSING
    exit 1;
}
Archive::Zip::setErrorHandler(sub { });    # we report failures ourselves

sub usage {
    my ($code) = @_;
    my $out = $code ? \*STDERR : \*STDOUT;
    open my $self, '<', $0 or die "cannot read $0: $!\n";
    <$self>;    # skip the #! line
    while (my $line = <$self>) {
        last unless $line =~ s/^#[ ]?//;
        print {$out} $line;
    }
    close $self;
    exit $code;
}

sub step { print "\n== $_[0]\n" }
sub ok   { print "  ok    $_[0]\n" }
sub note { print "        $_[0]\n" }
sub warn_ { print "  warn  $_[0]\n" }
sub fail { print "  FAIL  $_[0]\n"; exit 1 }

# ------------------------------------------------------------------ layout --

step 'Preflight';

my $root = $opt{install};
fail "'$root' is not a directory." unless -d $root;

# macOS bundles keep everything under Contents/Resources.
my $resources = $root;
if (!-f File::Spec->catfile($resources, 'omni.ja')
    && -f File::Spec->catfile($root, 'Contents', 'Resources', 'omni.ja'))
{
    $resources = File::Spec->catdir($root, 'Contents', 'Resources');
    note "macOS bundle detected, using $resources";
}

my $omni   = File::Spec->catfile($resources, 'omni.ja');
my $appini = File::Spec->catfile($resources, 'application.ini');
fail "'$omni' not found. Is --install correct?"   unless -f $omni;
fail "'$appini' not found. Is --install correct?" unless -f $appini;

check_not_running();

my ($version, $build_id) = read_app_ini($appini);
ok "Installed: Thunderbird $version (build $build_id)";

my $manifest_path = File::Spec->catfile($opt{payload}, 'manifest.json');
fail "'$manifest_path' not found. Is --payload correct?" unless -f $manifest_path;
my $manifest_json = slurp($manifest_path);
$manifest_json =~ s/^\x{ef}\x{bb}\x{bf}//;    # tolerate a UTF-8 BOM
my $manifest = decode_json($manifest_json);
# targetVersions lists every release the payload is known to apply to. Releases
# that leave the patched modules untouched can simply be added to it.
my @targets = @{ $manifest->{targetVersions} || [] };
push @targets, $manifest->{targetVersion} if $manifest->{targetVersion};
fail "'$manifest_path' names no target version." unless @targets;
my $targets_text = join ', ', @targets;

ok "Payload:   $manifest->{name}, built for $targets_text";
note "from $manifest->{sourceTree}";

my $backup = File::Spec->catfile($resources, "omni.ja.bak-$version-$build_id");

# ----------------------------------------------------------------- restore --

if ($opt{restore}) {
    step 'Restore';
    fail "No backup at '$backup'." unless -f $backup;
    if ($DRY) {
        ok "would copy '$backup' over '$omni'";
    } else {
        copy($backup, $omni) or fail "copy failed: $!";
        ok 'restored omni.ja from backup';
    }
    purge_startup_cache();
    print "\nDone. Thunderbird is back to stock.\n\n";
    exit 0;
}

unless (grep { $_ eq $version } @targets) {
    if ($opt{force}) {
        warn_ "version mismatch: installed $version, payload built for $targets_text";
        note 'continuing because --force was given; the SHA-256 checks below still apply';
    } else {
        fail "version mismatch: installed $version, payload built for $targets_text. Pass --force to try anyway.";
    }
}

# ------------------------------------------------------------------ verify --

step sprintf(
    'Verifying the %d modules inside omni.ja',
    scalar @{ $manifest->{entries} }
);

my $zip = Archive::Zip->new;
fail "cannot read '$omni' as a zip archive." unless $zip->read($omni) == Archive::Zip::AZ_OK();

my (@to_patch, $already);
$already = 0;
for my $e (@{ $manifest->{entries} }) {
    my $source = File::Spec->catfile($opt{payload}, 'payload', "$e->{file}.new");
    fail "payload file '$source' is missing." unless -f $source;

    my $member = $zip->memberNamed($e->{entry});
    fail "omni.ja has no entry '$e->{entry}'." unless $member;

    # contents() returns ($data, $status) in list context, so pin it to scalar.
    my $data = scalar $zip->contents($member);
    my $have = uc sha256_hex($data);
    if ($have eq uc $e->{origSha}) {
        ok "$e->{entry} - stock, will be patched";
        push @to_patch, { entry => $e->{entry}, source => $source, new_sha => uc $e->{newSha} };
    } elsif ($have eq uc $e->{newSha}) {
        ok "$e->{entry} - already patched, leaving alone";
        $already++;
    } else {
        print "  FAIL  $e->{entry} - unrecognised content\n";
        note "expected " . uc $e->{origSha};
        note "found    $have";
        fail 'This installation is not the one the payload was built against. Nothing was changed.';
    }
}

unless (@to_patch) {
    print "\nAll $already modules are already patched. Nothing to do.\n\n";
    exit 0;
}

# ------------------------------------------------------------------- apply --

step 'Backup';
if (-f $backup) {
    ok 'backup already exists, keeping it: ' . basename($backup);
} elsif ($DRY) {
    ok 'would copy omni.ja to ' . basename($backup);
} else {
    copy($omni, $backup) or fail "copy failed: $!";
    ok 'saved ' . basename($backup);
}

step 'Patching omni.ja';
if ($DRY) {
    ok "would replace $_->{entry}" for @to_patch;
    print "\nDry run only, nothing was written.\n\n";
    exit 0;
}

for my $p (@to_patch) {
    $zip->removeMember($p->{entry});
    my $member = $zip->addString(slurp($p->{source}), $p->{entry});
    fail "could not add $p->{entry}." unless $member;
    $member->desiredCompressionMethod(Archive::Zip::COMPRESSION_DEFLATED());
    ok "replaced $p->{entry}";
}
fail 'writing omni.ja failed. Restore with --restore.'
    unless $zip->overwrite() == Archive::Zip::AZ_OK();

step 'Verifying the result';
my $check = Archive::Zip->new;
fail 'the rewritten omni.ja is not readable. Restore with --restore.'
    unless $check->read($omni) == Archive::Zip::AZ_OK();
for my $e (@{ $manifest->{entries} }) {
    my $member = $check->memberNamed($e->{entry});
    my $have = 'MISSING';
    if ($member) {
        my $data = scalar $check->contents($member);
        $have = uc sha256_hex($data);
    }
    fail "$e->{entry} did not come out as expected. Roll back with --restore."
        if $have ne uc $e->{newSha};
}
ok 'every module matches the expected hash';

# ------------------------------------------------------------------- cache --

step 'Startup cache';
purge_startup_cache();

if ($^O eq 'darwin') {
    step 'macOS code signature';
    warn_ 'editing omni.ja invalidates the bundle signature';
    note 'if Thunderbird refuses to start, re-sign it ad hoc:';
    note "  codesign --force --deep --sign - '$root'";
}

my $exe = $^O eq 'MSWin32' ? File::Spec->catfile($resources, 'thunderbird.exe') : 'thunderbird';
print "\nDone. Parallel POP3 checking is active, there is nothing to switch on.\n";
print "Start Thunderbird once with -purgecaches:\n";
if ($opt{profile}) {
    print qq{  "$exe" -no-remote -profile "$opt{profile}" -purgecaches\n};
} else {
    print qq{  "$exe" -purgecaches\n};
}
print "Afterwards start it normally.\n";
print "Roll back with: --restore\n\n";

# --------------------------------------------------------------- utilities --

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or fail "cannot read '$path': $!";
    local $/;
    my $data = <$fh>;
    close $fh;
    return $data;
}

sub read_app_ini {
    my ($path) = @_;
    my ($ver, $build);
    open my $fh, '<', $path or fail "cannot read '$path': $!";
    while (my $line = <$fh>) {
        $ver   = $1 if !defined $ver   && $line =~ /^Version=(.+?)\s*$/;
        $build = $1 if !defined $build && $line =~ /^BuildID=(.+?)\s*$/;
    }
    close $fh;
    fail "no Version= line in '$path'." unless defined $ver;
    return ($ver, defined $build ? $build : 'unknown');
}

# Writing omni.ja while the application has it mapped corrupts the install, so
# refuse when we can see a running process and say so when we cannot tell.
sub check_not_running {
    my $out;
    if ($^O eq 'MSWin32') {
        $out = `tasklist /FI "IMAGENAME eq thunderbird.exe" /NH 2>NUL`;
        if (defined $out && $out =~ /thunderbird\.exe/i) {
            fail 'Thunderbird is running. Close it first.';
        }
    } else {
        $out = `ps -A -o comm= 2>/dev/null`;
        if (defined $out && $out =~ /(^|\/)thunderbird(-bin)?$/mi) {
            fail 'Thunderbird is running. Close it first.';
        }
    }
    if (defined $out && $out ne '') {
        ok 'Thunderbird is not running';
    } else {
        warn_ 'could not determine whether Thunderbird is running - make sure it is closed';
    }
}

sub purge_startup_cache {
    unless ($opt{profile}) {
        warn_ 'no --profile given, so the startup cache was NOT cleared';
        note 'delete <profile>/startupCache yourself, or the patch will have no effect';
        return;
    }
    my $cache = File::Spec->catdir($opt{profile}, 'startupCache');
    unless (-d $cache) {
        ok "no startupCache in $opt{profile}, nothing to delete";
        return;
    }
    if ($DRY) {
        ok "would delete '$cache'";
        return;
    }
    remove_tree($cache, { error => \my $err });
    if ($err && @$err) {
        fail "could not delete '$cache'.";
    }
    ok "deleted $cache";
}
