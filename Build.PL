#!/usr/bin/perl

use strict;
use warnings;

use Config;
use File::Spec;

my %prereqs = qw(
    Encode::Locale                  0
    ExtUtils::MakeMaker             6.80
    ExtUtils::ParseXS               3.22
    File::Basename                  0
    File::Spec                      0
    Getopt::Long                    0
    Math::PlanePath                 53
    Module::Build::WithXSpp         0.14
    Moo                             1.003001
    Scalar::Util                    0
    Test::Harness                   0
    Test::More                      0
    IO::Scalar                      0
    Time::HiRes                     0
);
my %recommends = qw(
    Class::XSAccessor               0
    XML::SAX::ExpatXS               0
);

my $sudo    = grep { $_ eq '--sudo' } @ARGV;
my $gui     = grep { $_ eq '--gui' } @ARGV;
my $xs_only = grep { $_ eq '--xs' }  @ARGV;
if ($gui) {
    %prereqs = qw(
    Wx                              0.9918
    );
	#DIY remove warning of eclipse, add necessary packages
#    %recommends = qw(
#    Growl::GNTP                     0.15
#    Wx::GLCanvas                    0
#    OpenGL                          0
#    );
    %recommends = qw(
    Growl::GNTP                     0.15
    Wx::GLCanvas                    0
    OpenGL                          0
	PDF::API2						0
	OpenGL::Image					0
	JSON							0
	Class::Accessor					0
    );
	#DIY end - PNI
} elsif ($xs_only) {
    %prereqs = %recommends = ();
}

my @missing_prereqs = ();
if ($ENV{SLIC3R_NO_AUTO}) {
    foreach my $module (sort keys %prereqs) {
        my $version = $prereqs{$module};
        next if eval "use $module $version; 1";
        push @missing_prereqs, $module if exists $prereqs{$module};
        print "Missing prerequisite $module $version\n";
    }
    foreach my $module (sort keys %recommends) {
        my $version = $recommends{$module};
        next if eval "use $module $version; 1";
        print "Missing optional $module $version\n";
    }
} else {
    my @try = (
        $ENV{CPANM} // (),
        File::Spec->catfile($Config{sitebin}, 'cpanm'),
        File::Spec->catfile($Config{installscript}, 'cpanm'),
    );
    
    my $cpanm;
    foreach my $path (@try) {
        if (-e $path) {  # don't use -x because it fails on Windows
            $cpanm = $path;
            last;
        }
    }
    if (!$cpanm) {
        if ($^O =~ /^(?:darwin|linux)$/ && system(qw(which cpanm)) == 0) {
            $cpanm = 'cpanm';
        }
    }
    die <<'EOF'
cpanm was not found. Please install it before running this script.

There are several ways to install cpanm, try one of these:

    apt-get install cpanminus
    curl -L http://cpanmin.us | perl - --sudo App::cpanminus
    cpan App::cpanminus

If it is installed in a non-standard location you can do:
    
    CPANM=/path/to/cpanm perl Build.PL

EOF
        if !$cpanm;
    my @cpanm_args = ();
    push @cpanm_args, "--sudo" if $sudo;

    # make sure our cpanm is updated (old ones don't support the ~ syntax)
    system $cpanm, @cpanm_args, 'App::cpanminus';
    
    # install the Windows-compatible Math::Libm
    if ($^O eq 'MSWin32' && !eval "use Math::Libm; 1") {
        system $cpanm, @cpanm_args, 'https://github.com/alexrj/Math-Libm/tarball/master';
    }
    
    my %modules = (%prereqs, %recommends);
    foreach my $module (sort keys %modules) {
        my $version = $modules{$module};
        my @cmd = ($cpanm, @cpanm_args, "$module~$version");
        if ($module eq 'XML::SAX::ExpatXS' && $^O eq 'MSWin32') {
            my $mingw = 'C:\MinGW\mingw64';
            $mingw = 'C:\MinGW\mingw32' if !-d $mingw;
            if (!-d $mingw) {
                print "Could not find the MinGW directory at $mingw; skipping XML::SAX::ExpatXS (only needed for faster parsing of AMF files)\n";
            } else {
                push @cmd, sprintf('--configure-args="EXPATLIBPATH=%s\lib EXPATINCPATH=%s\include"', $mingw, $mingw);
            }
        }
        my $res = system @cmd;
        if ($res != 0) {
            if (exists $prereqs{$module}) {
                push @missing_prereqs, $module;
            } else {
                printf "Don't worry, this module is optional.\n";
            }
        }
    }
    
    if (!$gui) {
        # clean xs directory before reinstalling, to make sure Build is called
        # with current perl binary
        if (-e './xs/Build') {
            if ($^O eq 'MSWin32') {
                system '.\xs\Build', 'distclean';
            } else {
                system './xs/Build', 'distclean';
            }
        }
        my $res = system $cpanm, @cpanm_args, '--reinstall', '--verbose', './xs';
        if ($res != 0) {
            die "The XS/C++ code failed to compile, aborting\n";
        }
    }
}

if (@missing_prereqs) {
    printf "The following prerequisites failed to install: %s\n", join(', ', @missing_prereqs);
    exit 1;
} elsif (!$gui) {
    eval "use App::Prove; 1" or die "Failed to load App::Prove";
    my $res = App::Prove->new->run ? 0 : 1;
    if ($res == 0) {
        print "If you also want to use the GUI you can now run `perl Build.PL --gui` to install the required modules.\n";
    } else {
        print "Some tests failed. Please report the failure to the author!\n";
    }
    exit $res;
}

__END__
