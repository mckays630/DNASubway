#!/usr/bin/perl
use strict;
use warnings;
use lib '../lib/perl';

use DNALC::Pipeline::Chado::Utils;
use Getopt::Long;
use Pod::Usage;

=head1 NAME

load_analysis_results.pl - Loads a user provided GFF into chado

=head1 SYNOPSIS

  % load_fasta.pl --username <name> --data_dir <path>

=head1 COMMAND-LINE OPTIONS

=over

=item username

The name of the web-based user

=item data_dir
 
Path to the directory containing GFF3 files

=item project_id

Project ID number

=item gbrowse_template

The name of the template for creating GBrowse conf files (default:gbrowse.template)

=item gbrowse_confdir

The path to the GBrowse configuration file (default:/etc/httpd/conf/gbrowse.conf)

=item profile

The name of the GMOD conf file to use for database connection info (default:default)

=back

=head1 DESCRIPTION

This script takes a user provided fasta file and creates a feature for it in the
feature table and adds the sequence to it.

=head1 AUTHOR

Scott Cain E<lt>cain.cshl@gmail.orgE<gt>

Copyright (c) 2009

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

my ($PROFILE, $DATADIR, $USERNAME, $GBROWSETEMPLATE, $GBROWSECONFDIR, $HELP, $PROJECTID);

GetOptions(
  'username=s'         => \$USERNAME,
  'data_dir=s'         => \$DATADIR,
  'gbrowse_template=s' => \$GBROWSETEMPLATE,
  'gbrowse_confdir=s'  => \$GBROWSECONFDIR,
  'profile=s'          => \$PROFILE,
  'project_id=s'       => \$PROJECTID,
  'help'               => \$HELP,
) or  pod2usage(-verbose => 1, -exitval => 1);

pod2usage(-verbose => 2, -exitval => 1) if $HELP;

die unless $USERNAME;
die unless $DATADIR;
die unless $PROJECTID;

$PROFILE         ||= 'default';
$GBROWSECONFDIR  ||= '/etc/httpd/conf/gbrowse.conf';
$GBROWSETEMPLATE ||= 'gbrowse.template';


my %args = (
  'username'        => $USERNAME,
  'profile'         => $PROFILE,
  'data_dir'        => $DATADIR,
  'growse_template' => $GBROWSETEMPLATE,
  'gbrowse_confdir' => $GBROWSECONFDIR,
  'project_id'      => $PROJECTID,
);

my $utils = DNALC::Pipeline::Chado::Utils->new(%args);

$utils->load_database();
$utils->create_gbrowse_conf($PROJECTID);

exit(0);
