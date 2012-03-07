#
# Copyright (c) 2011 Aconex.  All Rights Reserved.
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
use JSON;
use PCP::PMDA;
use LWP::Simple;

my $es_port = 9200;
my $es_instance = 'localhost';
my $es_user = 'nobody';
use vars qw($pmda $es_cluster);
use vars qw($es_nodes $es_nodestats $es_root $es_transportstats $es_shardstats);

my $nodes_indom = 0;
my @nodes_instances;
my @nodes_instance_ids;

my @cluster_cache;		# time of last refresh for each cluster
my $cache_interval = 2;		# min secs between refreshes for clusters

# Configuration files for overriding the above settings
for my $file (pmda_config('PCP_PMDAS_DIR') . '/elasticsearch/es.conf', 'es.conf') {
    eval `cat $file` unless ! -f $file;
}
my $baseurl = "http://$es_instance:$es_port/";

# crack json data structure, extract node names
sub es_node_instances
{
    my $nodeIDs = shift;
    my $i = 0;

    @nodes_instances = ();
    @nodes_instance_ids = ();
    foreach my $node (keys %$nodeIDs) {
	my $name = $nodeIDs->{$node}->{'name'};
	$nodes_instances[$i*2] = $i;
	$nodes_instances[($i*2)+1] = $name;
	$nodes_instance_ids[$i*2] = $i;
	$nodes_instance_ids[($i*2)+1] = $node;
	$i++;
	# $pmda->log("es_instances added node: $name ($node)");
    }
    $pmda->replace_indom($nodes_indom, \@nodes_instances);
}

sub es_refresh
{
    my ($cluster) = @_;
    my $now = time;

    if (defined($cluster_cache[$cluster]) &&
        $now - $cluster_cache[$cluster] <= $cache_interval) {
	# $pmda->log("es_refresh $cluster - no refresh needed yet");
	return;
    }

    if ($cluster == 0) {	# Update the cluster metrics
	my $content = get($baseurl . "_cluster/health");
	if (defined($content)) {
	    $es_cluster = decode_json($content);
	} else {
	    # $pmda->log("es_refresh $cluster failed $content");
	    $es_cluster = undef;
	}
    } elsif ($cluster == 1) {	# Update the node metrics
	my $content = get($baseurl . "_cluster/nodes/stats?all");
	if (defined($content)) {
	    $es_nodestats = decode_json($content);
	    es_node_instances($es_nodestats->{'nodes'});
	} else {
	    # $pmda->log("es_refresh $cluster failed $content");
	    $es_nodestats = undef;
	}
    } elsif ($cluster == 2) {	# Update the other node metrics
	my $content = get($baseurl . "_cluster/nodes?all");
	if (defined($content)) {
	    $es_nodes = decode_json($content);
	    es_node_instances($es_nodes->{'nodes'});
	} else {
	    # $pmda->log("es_refresh $cluster failed $content");
	    $es_nodes = undef;
	}
    } elsif ($cluster == 3) {	# Update the root metrics
	my $content = get($baseurl);
	if (defined($content)) {
	    $es_root = decode_json($content);
	} else {
	    # $pmda->log("es_refresh $cluster failed $content");
	    $es_root = undef;
	}
    }
    $cluster_cache[$cluster] = $now;
}

sub es_lookup_node
{
    my ($json, $inst) = @_;
    my $nodeID = $nodes_instance_ids[($inst*2)+1];
    return $json->{'nodes'}->{$nodeID};
}

# iterate over metric-name components, performing hash lookups as we go.
sub es_value
{
    my ( $values, $names ) = @_;
    my ( $value, $name );

    foreach $name (@$names) {
	$value = $values->{$name};
	return (PM_ERR_APPVERSION, 0) unless (defined($value));
	$values = $value;
    }
    return (PM_ERR_APPVERSION, 0) unless (defined($value));
    return ($value, 1);
}

# translate status string into a numeric code for pmie and friends
sub es_status
{
    my ($value) = @_;

    if (!defined($value)) {
	return (PM_ERR_AGAIN, 0);
    } elsif ($value eq "green" || $value eq "false") {
	return (0, 1);
    } elsif ($value eq "yellow" || $value eq "true") {
	return (1, 1);
    } elsif ($value eq "red") {
	return (2, 1);
    }
    return (-1, 1);	# unknown
}

sub es_fetch_callback
{
    my ($cluster, $item, $inst) = @_;
    my $metric_name = pmda_pmid_name($cluster, $item);
    my @metric_subnames;
    my ($node, $json);

    # $pmda->log("es_fetch_callback: $metric_name $cluster.$item ($inst)");

    # split into sub-names, remove first couple (e.g. elasticsearch.node.)
    # except for exception cases (like elasticsearch.version.number).
    @metric_subnames = split(/\./, $metric_name);
    splice(@metric_subnames, 0, $cluster != 3 ? 2 : 1);

    if ($cluster == 0) {
	if (!defined($es_cluster))	{ return (PM_ERR_AGAIN, 0); }
	if ($inst != PM_IN_NULL)	{ return (PM_ERR_INST, 0); }

	# cluster.timed_out and cluster.status (numeric codes)
	if ($item == 1) {
	    my $value = $es_cluster->{'status'};
	    return (PM_ERR_APPVERSION, 0) unless (defined($value));
	    return ($value, 1);
	}
	elsif ($item == 2 || $item == 10) {
	    return es_status($es_cluster->{$metric_subnames[0]});
	}
	return es_value($es_cluster, \@metric_subnames);
    }
    elsif ($cluster == 1) {
	if ($inst == PM_IN_NULL)	{ return (PM_ERR_INST, 0); }
	if ($inst > @nodes_instances)	{ return (PM_ERR_INST, 0); }

	$node = es_lookup_node($es_nodestats, $inst);
	if (!defined($node))		{ return (PM_ERR_AGAIN, 0); }
	return es_value($node, \@metric_subnames);
    }
    elsif ($cluster == 2) {
	if ($inst == PM_IN_NULL)	{ return (PM_ERR_INST, 0); }
	if ($inst > @nodes_instances)	{ return (PM_ERR_INST, 0); }

	$node = es_lookup_node($es_nodes, $inst);
	if (!defined($node))		{ return (PM_ERR_AGAIN, 0); }
	return es_value($node, \@metric_subnames);
    }
    elsif ($cluster == 3) {
	if (!defined($es_root))		{ return (PM_ERR_AGAIN, 0); }
	if ($inst != PM_IN_NULL)	{ return (PM_ERR_INST, 0); }

	return es_value($es_root, \@metric_subnames);
    }
    return (PM_ERR_PMID, 0);
}

$pmda = PCP::PMDA->new('elasticsearch', 108);

# cluster stats
$pmda->add_metric(pmda_pmid(0,0), PM_TYPE_STRING, PM_INDOM_NULL,
		  PM_SEM_INSTANT, pmda_units(0,0,0,0,0,0),
		  'elasticsearch.cluster.cluster_name',
		  'Name of the elasticsearch cluster', '');
$pmda->add_metric(pmda_pmid(0,1), PM_TYPE_STRING, PM_INDOM_NULL,
		  PM_SEM_INSTANT, pmda_units(0,0,0,0,0,0),
		  'elasticsearch.cluster.status.colour',
		  'Status (green,yellow,red) of the elasticsearch cluster', '');
$pmda->add_metric(pmda_pmid(0,2), PM_TYPE_U32, PM_INDOM_NULL,
		  PM_SEM_INSTANT, pmda_units(0,0,0,0,0,0),
		  'elasticsearch.cluster.timed_out',
		  'Timed out status (0:false,1:true) of the elasticsearch cluster',
		  'Maps the cluster timed-out status to a numeric value for alarming');
$pmda->add_metric(pmda_pmid(0,3), PM_TYPE_U32, PM_INDOM_NULL,
		  PM_SEM_INSTANT, pmda_units(0,0,0,0,0,0),
		  'elasticsearch.cluster.number_of_nodes',
		  'Number of nodes in the elasticsearch cluster', '');
$pmda->add_metric(pmda_pmid(0,4), PM_TYPE_U32, PM_INDOM_NULL,
		  PM_SEM_INSTANT, pmda_units(0,0,0,0,0,0),
		  'elasticsearch.cluster.number_of_data_nodes',
		  'Number of data nodes in the elasticsearch cluster', '');
$pmda->add_metric(pmda_pmid(0,5), PM_TYPE_U32, PM_INDOM_NULL,
		  PM_SEM_INSTANT, pmda_units(0,0,0,0,0,0),
		  'elasticsearch.cluster.active_primary_shards',
		  'Number of active primary shards in the elasticsearch cluster', '');
$pmda->add_metric(pmda_pmid(0,6), PM_TYPE_U32, PM_INDOM_NULL,
		  PM_SEM_INSTANT, pmda_units(0,0,0,0,0,0),
		  'elasticsearch.cluster.active_shards',
		  'Number of primary shards in the elasticsearch cluster', '');
$pmda->add_metric(pmda_pmid(0,7), PM_TYPE_U32, PM_INDOM_NULL,
		  PM_SEM_INSTANT, pmda_units(0,0,0,0,0,0),
		  'elasticsearch.cluster.relocating_shards',
		  'Number of relocating shards in the elasticsearch cluster', '');
$pmda->add_metric(pmda_pmid(0,8), PM_TYPE_U32, PM_INDOM_NULL,
		  PM_SEM_INSTANT, pmda_units(0,0,0,0,0,0),
		  'elasticsearch.cluster.initializing_shards',
		  'Number of initializing shards in the elasticsearch cluster', '');
$pmda->add_metric(pmda_pmid(0,9), PM_TYPE_U32, PM_INDOM_NULL,
		  PM_SEM_INSTANT, pmda_units(0,0,0,0,0,0),
		  'elasticsearch.cluster.unassigned_shards',
		  'Number of unassigned shards in the elasticsearch cluster', '');
$pmda->add_metric(pmda_pmid(0,10), PM_TYPE_32, PM_INDOM_NULL,
		  PM_SEM_INSTANT, pmda_units(0,0,0,0,0,0),
		  'elasticsearch.cluster.status.code',
		  'Status code (0:green,1:yellow,2:red) of the elasticsearch cluster',
		  'Maps the cluster status colour to a numeric value for alarming');

# node stats
$pmda->add_metric(pmda_pmid(1,0), PM_TYPE_U64, $nodes_indom,	# deprecated
		PM_SEM_INSTANT, pmda_units(1,0,0,PM_SPACE_BYTE,0,0),
		'elasticsearch.nodes.indices.size_in_bytes', '', '');
$pmda->add_metric(pmda_pmid(1,1), PM_TYPE_U64, $nodes_indom,	# deprecated
		PM_SEM_COUNTER, pmda_units(0,0,1,0,0,PM_COUNT_ONE),
		'elasticsearch.nodes.indices.docs.count', '', '');
$pmda->add_metric(pmda_pmid(1,2), PM_TYPE_U64, $nodes_indom,
		PM_SEM_INSTANT, pmda_units(0,0,1,0,0,PM_COUNT_ONE),
		'elasticsearch.nodes.indices.docs.num_docs',
		'Raw number of documents indexed by elasticsearch', '');
$pmda->add_metric(pmda_pmid(1,3), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,0,1,0,0,PM_COUNT_ONE),
		'elasticsearch.nodes.indices.cache.field_evictions', '', '');
$pmda->add_metric(pmda_pmid(1,4), PM_TYPE_U64, $nodes_indom,
		PM_SEM_INSTANT, pmda_units(1,0,0,PM_SPACE_BYTE,0,0),
		'elasticsearch.nodes.indices.cache.field_size_in_bytes', '', '');
$pmda->add_metric(pmda_pmid(1,5), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,0,1,0,0,PM_COUNT_ONE),
		'elasticsearch.nodes.indices.cache.filter_count', '', '');
$pmda->add_metric(pmda_pmid(1,6), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,0,1,0,0,PM_COUNT_ONE),
		'elasticsearch.nodes.indices.cache.filter_evictions', '', '');
$pmda->add_metric(pmda_pmid(1,7), PM_TYPE_U64, $nodes_indom,
		PM_SEM_INSTANT, pmda_units(1,0,0,PM_SPACE_BYTE,0,0),
		'elasticsearch.nodes.indices.cache.filter_size_in_bytes', '', '');
$pmda->add_metric(pmda_pmid(1,8), PM_TYPE_U64, $nodes_indom,
		PM_SEM_INSTANT, pmda_units(0,0,1,0,0,PM_COUNT_ONE),
		'elasticsearch.nodes.indices.merges.current', '', '');
$pmda->add_metric(pmda_pmid(1,9), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,0,1,0,0,PM_COUNT_ONE),
		'elasticsearch.nodes.indices.merges.total', '', '');
$pmda->add_metric(pmda_pmid(1,10), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,1,0,0,PM_TIME_MSEC,0),
		'elasticsearch.nodes.indices.merges.total_time_in_millis',
		'', '');
$pmda->add_metric(pmda_pmid(1,11), PM_TYPE_U64, $nodes_indom,
		PM_SEM_INSTANT, pmda_units(0,1,0,0,PM_TIME_MSEC,0),
		'elasticsearch.nodes.jvm.uptime_in_millis',
		'Number of milliseconds each elasticsearch node has been running', '');
$pmda->add_metric(pmda_pmid(1,12), PM_TYPE_STRING, $nodes_indom,
		PM_SEM_INSTANT, pmda_units(0,0,0,0,0,0),
		'elasticsearch.nodes.jvm.uptime',
		'Time (as a string) that each elasticsearch node has been up', '');
$pmda->add_metric(pmda_pmid(1,13), PM_TYPE_U64, $nodes_indom,
		PM_SEM_INSTANT, pmda_units(1,0,0,PM_SPACE_BYTE,0,0),
		'elasticsearch.nodes.jvm.mem.heap_used_in_bytes',
		'Actual amount of memory in use for the Java heap', '');
$pmda->add_metric(pmda_pmid(1,14), PM_TYPE_U64, $nodes_indom,
		PM_SEM_INSTANT, pmda_units(1,0,0,PM_SPACE_BYTE,0,0),
		'elasticsearch.nodes.jvm.mem.heap_committed_in_bytes',
		'Virtual memory size', '');
$pmda->add_metric(pmda_pmid(1,15), PM_TYPE_U64, $nodes_indom,
		PM_SEM_INSTANT, pmda_units(1,0,0,PM_SPACE_BYTE,0,0),
		'elasticsearch.nodes.jvm.mem.non_heap_used_in_bytes',
		'Actual memory in use by Java excluding heap space', '');
$pmda->add_metric(pmda_pmid(1,16), PM_TYPE_U64, $nodes_indom,
		PM_SEM_INSTANT, pmda_units(1,0,0,PM_SPACE_BYTE,0,0),
		'elasticsearch.nodes.jvm.mem.non_heap_committed_in_bytes',
		'Virtual memory size excluding heap', '');
$pmda->add_metric(pmda_pmid(1,17), PM_TYPE_U32, $nodes_indom,
		PM_SEM_INSTANT, pmda_units(0,0,0,0,0,0),
		'elasticsearch.nodes.jvm.threads.count',
		'Number of Java threads currently in use on each node', '');
$pmda->add_metric(pmda_pmid(1,18), PM_TYPE_U32, $nodes_indom,
		PM_SEM_INSTANT, pmda_units(0,0,0,0,0,0),
		'elasticsearch.nodes.jvm.threads.peak_count',
		'Maximum observed Java threads in use on each node', '');
$pmda->add_metric(pmda_pmid(1,19), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,0,1,0,0,PM_COUNT_ONE),
		'elasticsearch.nodes.jvm.gc.collection_count',
		'Count of Java garbage collections', '');
$pmda->add_metric(pmda_pmid(1,20), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,1,0,0,PM_TIME_MSEC,0),
		'elasticsearch.nodes.jvm.gc.collection_time_in_millis',
		'Time spent performing garbage collections in Java', '');
$pmda->add_metric(pmda_pmid(1,21), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,0,1,0,0,PM_COUNT_ONE),
		'elasticsearch.nodes.jvm.gc.collectors.Copy.collection_count',
		'', '');
$pmda->add_metric(pmda_pmid(1,22), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,1,0,0,PM_TIME_MSEC,0),
		'elasticsearch.nodes.jvm.gc.collectors.Copy.collection_time_in_millis',
		'', '');
$pmda->add_metric(pmda_pmid(1,23), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,0,1,0,0,PM_COUNT_ONE),
		'elasticsearch.nodes.jvm.gc.collectors.ParNew.collection_count',
		'', '');
$pmda->add_metric(pmda_pmid(1,24), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,1,0,0,PM_TIME_MSEC,0),
		'elasticsearch.nodes.jvm.gc.collectors.ParNew.collection_time_in_millis',
		'', '');
$pmda->add_metric(pmda_pmid(1,25), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,0,1,0,0,PM_COUNT_ONE),
		'elasticsearch.nodes.jvm.gc.collectors.ConcurrentMarkSweep.collection_count',
		'', '');
$pmda->add_metric(pmda_pmid(1,26), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,1,0,0,PM_TIME_MSEC,0),
		'elasticsearch.nodes.jvm.gc.collectors.ConcurrentMarkSweep.collection_time_in_millis',
		'', '');
$pmda->add_metric(pmda_pmid(1,27), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,0,1,0,0,PM_COUNT_ONE),
		'elasticsearch.nodes.indices.docs.deleted',
		'', '');
$pmda->add_metric(pmda_pmid(1,28), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,0,1,0,0,PM_COUNT_ONE),
		'elasticsearch.nodes.indices.indexing.index_total',
		'', '');
$pmda->add_metric(pmda_pmid(1,29), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,1,0,0,PM_TIME_MSEC,0),
		'elasticsearch.nodes.indices.indexing.index_time_in_millis',
		'', '');
$pmda->add_metric(pmda_pmid(1,30), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,0,1,0,0,PM_COUNT_ONE),
		'elasticsearch.nodes.indices.indexing.delete_total',
		'', '');
$pmda->add_metric(pmda_pmid(1,31), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,1,0,0,PM_TIME_MSEC,0),
		'elasticsearch.nodes.indices.indexing.delete_time_in_millis',
		'', '');
$pmda->add_metric(pmda_pmid(1,32), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,0,1,0,0,PM_COUNT_ONE),
		'elasticsearch.nodes.indices.merges.current_docs',
		'', '');
$pmda->add_metric(pmda_pmid(1,33), PM_TYPE_U64, $nodes_indom,
		PM_SEM_INSTANT, pmda_units(1,0,0,PM_SPACE_BYTE,0,0),
		'elasticsearch.nodes.indices.merges.current_size_in_bytes',
		'', '');
$pmda->add_metric(pmda_pmid(1,34), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,0,1,0,0,PM_COUNT_ONE),
		'elasticsearch.nodes.indices.merges.total_docs',
		'', '');
$pmda->add_metric(pmda_pmid(1,35), PM_TYPE_U64, $nodes_indom,
		PM_SEM_INSTANT, pmda_units(1,0,0,PM_SPACE_BYTE,0,0),
		'elasticsearch.nodes.indices.merges.total_size_in_bytes',
		'', '');
$pmda->add_metric(pmda_pmid(1,36), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,0,1,0,0,PM_COUNT_ONE),
		'elasticsearch.nodes.indices.refresh.total',
		'', '');
$pmda->add_metric(pmda_pmid(1,37), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,1,0,0,PM_TIME_MSEC,0),
		'elasticsearch.nodes.indices.refresh.total_time_in_millis',
		'', '');
$pmda->add_metric(pmda_pmid(1,38), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,0,1,0,0,PM_COUNT_ONE),
		'elasticsearch.nodes.indices.flush.total',
		'', '');
$pmda->add_metric(pmda_pmid(1,39), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,1,0,0,PM_TIME_MSEC,0),
		'elasticsearch.nodes.indices.flush.total_time_in_millis',
		'', '');
$pmda->add_metric(pmda_pmid(1,40), PM_TYPE_U64, $nodes_indom,
		PM_SEM_INSTANT, pmda_units(0,0,0,0,0,0),
		'elasticsearch.nodes.process.timestamp', '', '');
$pmda->add_metric(pmda_pmid(1,41), PM_TYPE_U64, $nodes_indom,
		PM_SEM_INSTANT, pmda_units(0,0,0,0,0,0),
		'elasticsearch.nodes.process.open_file_descriptors', '', '');
$pmda->add_metric(pmda_pmid(1,42), PM_TYPE_U64, $nodes_indom,
		PM_SEM_INSTANT, pmda_units(0,0,0,0,0,0),
		'elasticsearch.nodes.process.cpu.percent', '', '');
$pmda->add_metric(pmda_pmid(1,43), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,1,0,0,PM_TIME_MSEC,0),
		'elasticsearch.nodes.process.cpu.sys_in_millis', '', '');
$pmda->add_metric(pmda_pmid(1,44), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,1,0,0,PM_TIME_MSEC,0),
		'elasticsearch.nodes.process.cpu.user_in_millis', '', '');
$pmda->add_metric(pmda_pmid(1,45), PM_TYPE_U64, $nodes_indom,
		PM_SEM_INSTANT, pmda_units(1,0,0,PM_SPACE_BYTE,0,0),
		'elasticsearch.nodes.process.mem.resident_in_bytes', '', '');
$pmda->add_metric(pmda_pmid(1,46), PM_TYPE_U64, $nodes_indom,
		PM_SEM_INSTANT, pmda_units(1,0,0,PM_SPACE_BYTE,0,0),
		'elasticsearch.nodes.process.mem.total_virtual_in_bytes',
		'', '');
$pmda->add_metric(pmda_pmid(1,47), PM_TYPE_U64, $nodes_indom,
		PM_SEM_INSTANT, pmda_units(1,0,0,PM_SPACE_BYTE,0,0),
		'elasticsearch.nodes.indices.store.size_in_bytes',
		'Size of indices store on each elasticsearch node', '');
$pmda->add_metric(pmda_pmid(1,48), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,0,1,0,0,PM_COUNT_ONE),
		'elasticsearch.nodes.indices.get.total',
		'', '');
$pmda->add_metric(pmda_pmid(1,49), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,1,0,0,PM_TIME_MSEC,0),
		'elasticsearch.nodes.indices.get.time_in_millis',
		'', '');
$pmda->add_metric(pmda_pmid(1,50), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,0,1,0,0,PM_COUNT_ONE),
		'elasticsearch.nodes.indices.get.exists_total',
		'', '');
$pmda->add_metric(pmda_pmid(1,51), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,1,0,0,PM_TIME_MSEC,0),
		'elasticsearch.nodes.indices.get.exists_time_in_millis',
		'', '');
$pmda->add_metric(pmda_pmid(1,52), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,0,1,0,0,PM_COUNT_ONE),
		'elasticsearch.nodes.indices.get.missing_total',
		'', '');
$pmda->add_metric(pmda_pmid(1,53), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,1,0,0,PM_TIME_MSEC,0),
		'elasticsearch.nodes.indices.get.missing_time_in_millis',
		'', '');
$pmda->add_metric(pmda_pmid(1,54), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,0,1,0,0,PM_COUNT_ONE),
		'elasticsearch.nodes.indices.search.query_total',
		'', '');
$pmda->add_metric(pmda_pmid(1,55), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,1,0,0,PM_TIME_MSEC,0),
		'elasticsearch.nodes.indices.search.query_time_in_millis',
		'', '');
$pmda->add_metric(pmda_pmid(1,56), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,0,1,0,0,PM_COUNT_ONE),
		'elasticsearch.nodes.indices.search.fetch_total',
		'', '');
$pmda->add_metric(pmda_pmid(1,57), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,1,0,0,PM_TIME_MSEC,0),
		'elasticsearch.nodes.indices.search.fetch_time_in_millis',
		'', '');
$pmda->add_metric(pmda_pmid(1,58), PM_TYPE_U32, $nodes_indom,
		PM_SEM_INSTANT, pmda_units(0,0,0,0,0,0),
		'elasticsearch.nodes.transport.server_open',
		'Count of open server connections', '');
$pmda->add_metric(pmda_pmid(1,59), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,0,1,0,0,PM_COUNT_ONE),
		'elasticsearch.nodes.transport.rx_count',
		'Receive transaction count', '');
$pmda->add_metric(pmda_pmid(1,60), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(1,0,0,PM_SPACE_BYTE,0,0),
		'elasticsearch.nodes.transport.rx_size_in_bytes',
		'Receive transaction size', '');
$pmda->add_metric(pmda_pmid(1,61), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,0,1,0,0,PM_COUNT_ONE),
		'elasticsearch.nodes.transport.tx_count',
		'Transmit transaction count', '');
$pmda->add_metric(pmda_pmid(1,62), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(1,0,0,PM_SPACE_BYTE,0,0),
		'elasticsearch.nodes.transport.tx_size_in_bytes',
		'Transmit transaction size', '');
$pmda->add_metric(pmda_pmid(1,63), PM_TYPE_U64, $nodes_indom,
		PM_SEM_INSTANT, pmda_units(0,0,0,0,0,0),
		'elasticsearch.nodes.http.current_open',
		'Number of currently open http connections', '');
$pmda->add_metric(pmda_pmid(1,64), PM_TYPE_U64, $nodes_indom,
		PM_SEM_COUNTER, pmda_units(0,0,1,0,0,PM_COUNT_ONE),
		'elasticsearch.nodes.http.total_opened',
		'Count of http connections opened since starting', '');

# node info stats
$pmda->add_metric(pmda_pmid(2,0), PM_TYPE_U32, $nodes_indom,
		PM_SEM_DISCRETE, pmda_units(0,0,0,0,0,0),
		'elasticsearch.nodes.jvm.pid',
		'Process identifier for elasticsearch on each node', '');
$pmda->add_metric(pmda_pmid(2,1), PM_TYPE_STRING, $nodes_indom,
		PM_SEM_INSTANT, pmda_units(0,0,0,0,0,0),
		'elasticsearch.nodes.jvm.version',
		'Java Runtime environment version', '');
$pmda->add_metric(pmda_pmid(2,2), PM_TYPE_STRING, $nodes_indom,
		PM_SEM_INSTANT, pmda_units(0,0,0,0,0,0),
		'elasticsearch.nodes.jvm.vm_name',
		'Name of the Java Virtual Machine running on each node', '');
$pmda->add_metric(pmda_pmid(2,3), PM_TYPE_STRING, $nodes_indom,
		PM_SEM_INSTANT, pmda_units(0,0,0,0,0,0),
		'elasticsearch.nodes.jvm.vm_version',
		'Java Virtual Machine version on each node', '');
$pmda->add_metric(pmda_pmid(2,4), PM_TYPE_U64, $nodes_indom,
		PM_SEM_INSTANT, pmda_units(1,0,0,PM_SPACE_BYTE,0,0),
		'elasticsearch.nodes.jvm.mem.heap_init_in_bytes',
		'Initial Java heap memory configuration size', '');
$pmda->add_metric(pmda_pmid(2,5), PM_TYPE_U64, $nodes_indom,
		PM_SEM_INSTANT, pmda_units(1,0,0,PM_SPACE_BYTE,0,0),
		'elasticsearch.nodes.jvm.mem.heap_max_in_bytes',
		'Maximum Java memory size', '');
$pmda->add_metric(pmda_pmid(2,6), PM_TYPE_U64, $nodes_indom,
		PM_SEM_INSTANT, pmda_units(1,0,0,PM_SPACE_BYTE,0,0),
		'elasticsearch.nodes.jvm.mem.non_heap_init_in_bytes',
		'Initial Java memory configuration size excluding heap space', '');
$pmda->add_metric(pmda_pmid(2,7), PM_TYPE_U64, $nodes_indom,
		PM_SEM_INSTANT, pmda_units(1,0,0,PM_SPACE_BYTE,0,0),
		'elasticsearch.nodes.jvm.mem.non_heap_max_in_bytes',
		'Maximum Java memory size excluding heap space', '');
$pmda->add_metric(pmda_pmid(2,8), PM_TYPE_U64, $nodes_indom,
		PM_SEM_DISCRETE, pmda_units(0,0,0,0,0,0),
		'elasticsearch.nodes.process.max_file_descriptors', '', '');

$pmda->add_metric(pmda_pmid(3,0), PM_TYPE_STRING, PM_INDOM_NULL,
		  PM_SEM_DISCRETE, pmda_units(0,0,0,0,0,0),
		  'elasticsearch.version.number',
		  'Version number of elasticsearch', '');

$pmda->add_indom($nodes_indom, \@nodes_instances,
		'Instance domain exporting each elasticsearch node', '');

$pmda->set_fetch_callback(\&es_fetch_callback);
$pmda->set_refresh(\&es_refresh);
$pmda->set_user($es_user);
$pmda->run;

=pod

=head1 NAME

pmdaelasticsearch - elasticsearch performance metrics domain agent (PMDA)

=head1 DESCRIPTION

B<pmdaelasticsearch> is a Performance Metrics Domain Agent (PMDA) which exports
metric values from elasticsearch.


=head1 INSTALLATION

This PMDA requires that elasticsearch is running on the local host and
is accepting queries on TCP port 9200


Install the elasticsearch PMDA by using the B<Install> script as root:

	# cd $PCP_PMDAS_DIR/elasticsearch
	# ./Install

To uninstall, do the following as root:

	# cd $PCP_PMDAS_DIR/elasticsearch
	# ./Remove

B<pmdaelasticsearch> is launched by pmcd(1) and should never be executed
directly.  The Install and Remove scripts notify pmcd(1) when
the agent is installed or removed.

=head1 FILES

=over

=item $PCP_PMDAS_DIR/elasticsearch/es.conf

optional configuration file for B<pmdaelasticsearch>

elasticsearch PMDA for PCP

=item $PCP_PMDAS_DIR/elasticsearch/Install

installation script for the B<pmdaelasticsearch> agent

=item $PCP_PMDAS_DIR/elasticsearch/Remove

undo installation script for the B<pmdaelasticsearch> agent

=item $PCP_LOG_DIR/pmcd/elasticsearch.log

default log file for error messages from B<pmdaelasticsearch>

=back

=head1 SEE ALSO

pmcd(1).
