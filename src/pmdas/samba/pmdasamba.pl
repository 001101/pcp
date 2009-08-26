#
# Copyright (c) 2009 Aconex.  All Rights Reserved.
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the
# Free Software Foundation; either version 2 of the License, or (at your
# option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
# for more details.
#

use strict;
use warnings;
use PCP::PMDA;

use vars qw( $pmda %metrics );
my $smbstats = 'smbstatus --profile';

#
# This is the main workhorse routine, both value extraction and
# namespace population is under-pinned by this.  The approach we
# use here is to extract profile output, construct a hash (keyed
# by metric ID), containing name and value pairs (array refs).
#
sub samba_fetch
{
    my $item = 0;
    my $cluster = 0;
    my $prefix = '';

    open(STATS, $smbstats) ||
	$pmda->err("pmdasamba failed to open $smbstats: $!");

    while (<STATS>) {
	if (m/^\*\*\*\* (\W+)/) {
	    my $heading = $1;

	    $item = 0;
	    if ($heading eq 'System Calls') {
		$cluster = 1; $prefix = 'syscalls';
	    } elsif ($heading eq 'Stat Cache') {
		$cluster = 2; $prefix = 'statcache';
	    } elsif ($heading eq 'Write Cache') {
		$cluster = 3; $prefix = 'writecache';
	    } elsif ($heading eq 'SMB Calls') {
		$cluster = 4; $prefix = 'smb';
	    } elsif ($heading eq 'Pathworks Calls') {
		$cluster = 5; $prefix = 'pathworks';
	    } elsif ($heading eq 'Trans2 Calls') {
		$cluster = 6; $prefix = 'trans2';
	    } elsif ($heading eq 'NT Transact Calls') {
		$cluster = 7; $prefix = 'NTtransact';
	    } elsif ($heading eq 'ACL Calls') {
		$cluster = 8; $prefix = 'acl';
	    } elsif ($heading eq 'NMBD Calls') {
		$cluster = 9; $prefix = 'nmb';
	    } else {
		$pmda->warn("pmdasamba failed to parse $smbstats heading: $1");
		$cluster = 0; $prefix = '';
	    }
	}
	# we've found a real name/value pair, work out PMID and hash it
	elsif (m/^(\W+):\w+(\d+)/) {
	    my @metric = ( $1, $2 );
	    my $pmid;

	    if ($cluster == 0) {
		$metric[0] = "samba.$metric[0]";
	    } else {
	        $metric[0] = "samba.$prefix.$metric[0]";
	    }
	    $pmid = pmda_pmid($cluster,$item++);
	    $metrics{$pmid} = \@metric;
	    # $pmda->log("metric: $metric[0], ID = $pmid, value = $metric[1]");
	}
    }
    close STATS;
}

sub samba_fetch_callback
{
    my ($cluster, $item, $inst) = @_;
    my $pmid = pmda_pmid($cluster, $item);
    my $value;

    # $pmda->log("samba_fetch_callback $metric_name $cluster:$item ($inst)\n");

    if ($inst != PM_IN_NULL)	{ return (PM_ERR_INST, 0); }

    # hash lookup based on PMID, value is $metrics{$pmid}[1]
    $value = $metrics{$pmid};
    if (!defined($value))	{ return (PM_ERR_APPVERSION, 0); }
    return ($value->[1], 1);
}

$pmda = PCP::PMDA->new('samba', 76);

samba_fetch();	# extract names and values into %metrics, keyed on PMIDs

# hash iterate, keys are PMIDs, names and values are in @metrics{$pmid}.
foreach my $pmid (sort(keys %metrics)) {
    my $name = $metrics{$pmid}[0];
    if ($name == 'samba.writecache.num_write_caches' ||
	$name == 'samba.writecache.allocated_caches') {
	$pmda->add_metric($pmid, PM_TYPE_U32, PM_INDOM_NULL, PM_SEM_INSTANT,
			pmda_units(0,0,1,0,0,PM_COUNT_ONE), $name, '', '');
    } elsif ($name =~ /_time$/) {
	$pmda->add_metric($pmid, PM_TYPE_U32, PM_INDOM_NULL, PM_SEM_COUNTER,
			pmda_units(0,1,0,0,PM_TIME_USEC,0), $name, '', '');
    } else {
	$pmda->add_metric($pmid, PM_TYPE_U32, PM_INDOM_NULL, PM_SEM_COUNTER,
			pmda_units(0,0,1,0,0,PM_COUNT_ONE), $name, '', '');
    }
    # $pmda->log("pmdasamba added metric $name\n");
}
close STATS;

$pmda->set_fetch(\&samba_fetch);
$pmda->set_fetch_callback(\&samba_fetch_callback);
$pmda->run;

=pod

=head1 NAME

pmdasamba - Linux virtualisation performance metrics domain agent (PMDA)

=head1 DESCRIPTION

B<pmdasamba> is a Performance Metrics Domain Agent (PMDA) which exports
metric values from Samba, a Windows SMB/CIFS server for UNIX.

In order for values to be made available by this PMDA, Samba must
be built with profiling support (WITH_PROFILE in "smbd -b" output).
Unlike many PMDAs it dynamically enumerates much of its metric hierarchy,
based on the contents of "smbstatus --profile".

When the agent is installed (see below), the Install script will attempt
to enable Samba statistics gathering, using "smbcontrol --profile".

=head1 INSTALLATION

If you want access to the names and values for the samba performance
metrics, do the following as root:

	# cd $PCP_PMDAS_DIR/samba
	# ./Install

If you want to undo the installation, do the following as root:

	# cd $PCP_PMDAS_DIR/samba
	# ./Remove

B<pmdasamba> is launched by pmcd(1) and should never be executed
directly.  The Install and Remove scripts notify pmcd(1) when
the agent is installed or removed.

=head1 FILES

=over

=item $PCP_PMDAS_DIR/samba/Install

installation script for the B<pmdasamba> agent

=item $PCP_PMDAS_DIR/samba/Remove

undo installation script for the B<pmdasamba> agent

=item $PCP_LOG_DIR/pmcd/samba.log

default log file for error messages from B<pmdasamba>

=back

=head1 SEE ALSO

pmcd(1), smbd(1) and samba(7).
