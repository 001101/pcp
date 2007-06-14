#! /bin/sh
#Tag 0x00010D13
#
# Copyright (c) 1998-2000,2003 Silicon Graphics, Inc.  All Rights Reserved.
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
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 59 Temple Place, Suite 330, Boston, MA  02111-1307 USA
# 
# Contact information: Silicon Graphics, Inc., 1500 Crittenden Lane,
# Mountain View, CA 94043, USA, or: http://www.sgi.com
# 
# $Id: pmie_check.sh,v 1.9 2005/01/19 00:04:20 kenmcd Exp $
#
# Administrative script to check pmie processes are alive, and restart
# them as required.
#

# Get standard environment
. /etc/pcp.env

PMIE=pmie

# added to handle problem when /var/log/pcp is a symlink, as first
# reported by Micah_Altman@harvard.edu in Nov 2001
#
_unsymlink_path()
{
    [ -z "$1" ] && return
    __d=`dirname $1`
    __real_d=`cd $__d 2>/dev/null && $PWDCMND`
    if [ -z "$__real_d" ]
    then
	echo $1
    else
	echo $__real_d/`basename $1`
    fi
}

have_pmieconf=false
if which pmieconf >/dev/null 2>&1
then
    have_pmieconf=true
fi

# error messages should go to stderr, not the GUI notifiers
#
unset PCP_STDERR


# constant setup
#
tmp=/tmp/$$
status=0
echo >$tmp.lock
trap "rm -f \`[ -f $tmp.lock ] && cat $tmp.lock\` $tmp.*; exit \$status" 0 1 2 3 15
prog=`basename $0`

# control file for pmie administration ... edit the entries in this
# file to reflect your local configuration
#
CONTROL=$PCP_VAR_DIR/config/pmie/control

# determine real name for localhost
LOCALHOSTNAME=`hostname | sed -e 's/\..*//'`
[ -z "$LOCALHOSTNAME" ] && LOCALHOSTNAME=localhost

# determine path for pwd command to override shell built-in
# (see BugWorks ID #595416).
PWDCMND=`which pwd 2>/dev/null | $PCP_AWK_PROG '
BEGIN	    	{ i = 0 }
/ not in /  	{ i = 1 }
/ aliased to /  { i = 1 }
 	    	{ if ( i == 0 ) print }
'`
if [ -z "$PWDCMND" ]
then
    #  Looks like we have no choice here...
    #  force it to a known IRIX location
    PWDCMND=/bin/pwd
fi

# determine whether SGI Embedded Support Partner events need to be used
CONFARGS="-F"
if which esplogger >/dev/null 2>&1
then
    CONFARGS='m global syslog_prefix $esp_prefix$'
fi

# option parsing
#
SHOWME=false
MV=mv
RM=rm
CP=cp
KILL=kill
TERSE=false
VERBOSE=false
VERY_VERBOSE=false
START_PMIE=true
usage="Usage: $prog [-NsTV] [-c control]"
while getopts c:NsTV? c
do
    case $c
    in
	c)	CONTROL="$OPTARG"
		;;
	N)	SHOWME=true
		MV="echo + mv"
		RM="echo + rm"
		CP="echo + cp"
		KILL="echo + kill"
		;;
	s)	START_PMIE=false
		;;
	T)	TERSE=true
		;;
	V)	if $VERBOSE
		then
		    VERY_VERBOSE=true
		else
		    VERBOSE=true
		fi
		;;
	?)	echo "$usage"
		status=1
		exit
		;;
    esac
done
shift `expr $OPTIND - 1`

if [ $# -ne 0 ]
then
    echo "$usage"
    status=1
    exit
fi

_error()
{
    echo "$prog: [$CONTROL:$line]"
    echo "Error: $1"
    echo "... automated performance reasoning for host \"$host\" unchanged"
    touch $tmp.err
}

_warning()
{
    echo "$prog [$CONTROL:$line]"
    echo "Warning: $1"
}

_message()
{
    case $1
    in
	'restart')
	    $PCP_ECHO_PROG $PCP_ECHO_N "Restarting pmie for host \"$host\" ..."
	    ;;
    esac
}

_lock()
{
    # demand mutual exclusion
    #
    fail=true
    rm -f $tmp.stamp
    for try in 1 2 3 4
    do
	if pmlock -v $logfile.lock >$tmp.out
	then
	    echo $logfile.lock >$tmp.lock
	    fail=false
	    break
	else
	    if [ ! -f $tmp.stamp ]
	    then
		touch -t `pmdate -30M %Y%m%d%H%M` $tmp.stamp
	    fi
	    if [ -n "`find $logfile.lock ! -newer $tmp.stamp -print 2>/dev/null`" ]
	    then
		_warning "removing lock file older than 30 minutes"
		ls -l $logfile.lock
		rm -f $logfile.lock
	    fi
	fi
	sleep 5
    done

    if $fail
    then
	# failed to gain mutex lock
	#
	if [ -f $logfile.lock ]
	then
	    _warning "is another PCP cron job running concurrently?"
	    ls -l $logfile.lock
	else
	    echo "$prog: `cat $tmp.out`"
	fi
	_warning "failed to acquire exclusive lock ($logfile.lock) ..."
	continue
    fi
}

_unlock()
{
    rm -f $logfile.lock
    echo >$tmp.lock
}

_check_logfile()
{
    if [ ! -f $logfile ]
    then
	echo "$prog: Error: cannot find pmie output file at \"$logfile\""
	if $TERSE
	then
	    :
	else
	    logdir=`dirname $logfile`
	    echo "Directory (`cd $logdir; $PWDCMND`) contents:"
	    LC_TIME=POSIX ls -la $logdir
	fi
    else
	echo "Contents of pmie output file \"$logfile\" ..."
	cat $logfile
    fi
}

_check_pmie_version()
{
    # the -C option was introduced at the same time as the $PCP_TMP_DIR/pmie
    # stats file support (required for pmie_check), so if this produces a
    # non-zero exit status, bail out
    # 
    if $PMIE -C /dev/null >/dev/null 2>&1
    then
	:
    else
	binary=`which $PMIE`
	echo "$prog: Error: wrong version of $binary installed"
	cat - <<EOF
You seem to have mixed versions in your Performance Co-Pilot (PCP)
installation, such that pmie(1) is incompatible with pmie_check(1).
EOF
	if [ "$PCP_PLATFORM" = "irix" ]
	then
	    #
	    # The following only makes sense on IRIX
	    #
	    echo
	    showfiles pcp\* \
	    | $PCP_AWK_PROG '/bin\/pmie$/ {print $4}' >$tmp.subsys

	    if [ -s $tmp.subsys ]
	    then
		echo "Currently $binary is installed from these subsystem(s):"
		echo
		versions `cat $tmp.subsys` </dev/null
		echo
	    else
		echo "The current installation history does not identify the subsystem(s)"
		echo "where $binary was installed from."
		echo
	    fi

	    case `uname -r`
	    in
		6.5*)
		    echo "Please upgrade pcp_eoe from the IRIX 6.5.5 (or later) distribution."
		    ;;
		*)
		    echo "Please upgrade pcp_eoe from the PCP 2.1 (or later) distribution."
		    ;;
	    esac
	fi

	status=1
	exit
    fi
}

_check_pmie()
{
    $VERBOSE && $PCP_ECHO_PROG $PCP_ECHO_N " [process $1] ""$PCP_ECHO_C"

    # wait until pmie process starts, or exits
    #
    delay=5
    [ ! -z "$PMCD_CONNECT_TIMEOUT" ] && delay=$PMCD_CONNECT_TIMEOUT
    x=5
    [ ! -z "$PMCD_REQUEST_TIMEOUT" ] && x=$PMCD_REQUEST_TIMEOUT

    # wait for maximum time of a connection and 20 requests
    #
    delay=`expr $delay + 20 \* $x`
    i=0
    while [ $i -lt $delay ]
    do
	$VERBOSE && $PCP_ECHO_PROG $PCP_ECHO_N ".""$PCP_ECHO_C"
	if [ -f $logfile ]
	then
	    # $logfile was previously removed, if it has appeared again then
	    # we know pmie has started ... if not just sleep and try again
	    #
	    if ls $PCP_TMP_DIR/pmie/$1 >$tmp.out 2>&1
	    then
		if grep "No such file or directory" $tmp.out >/dev/null
		then
		    :
		else
		    sleep 5
		    $VERBOSE && echo " done"
		    return 0
		fi
	    fi

	    _plist=`_get_pids_by_name pmie`
	    _found=false
	    for _p in `echo $_plist`
	    do
		[ $_p -eq $1 ] && _found=true
	    done

	    if $_found
	    then
		# process still here, just hasn't created its status file
		# yet, try again
		:
	    else
		$VERBOSE || _message restart
		echo " process exited!"
		if $TERSE
		then
		    :
		else
		    echo "$prog: Error: failed to restart pmie"
		    echo "Current pmie processes:"
		    ps $PCP_PS_ALL_FLAGS | tee $tmp.tmp | sed -n -e 1p
		    for _p in `echo $_plist`
		    do
			sed -n -e "/^[ ]*[^ ]* [ ]*$_p /p" < $tmp.tmp
		    done
		    echo
		fi
		_check_logfile
		return 1
	    fi
	fi
	sleep 5
	i=`expr $i + 5`
    done
    $VERBOSE || _message restart
    echo " timed out waiting!"
    if $TERSE
    then
	:
    else
	sed -e 's/^/	/' $tmp.out
    fi
    _check_logfile
    return 1
}

if $START_PMIE
then
    # ensure we have a pmie binary which supports the features we need
    # 
    _check_pmie_version
else
    # if pmie has never been started, there's no work to do to stop it
    # 
    [ ! -d $PCP_TMP_DIR/pmie ] && exit
    pmpost "stop pmie from $prog"
fi

if [ ! -f $CONTROL ]
then
    echo "$prog: Error: cannot find control file ($CONTROL)"
    status=1
    exit
fi

#  1.0 is the first release, and the version is set in the control file
#  with a $version=x.y line
#
version=1.0
eval `grep '^version=' $CONTROL | sort -rn`
if [ $version != "1.0" ]
then
    _error "unsupported version (got $version, expected 1.0)"
    status=1
    exit
fi

echo >$tmp.dir
rm -f $tmp.err $tmp.pmies

line=0
cat $CONTROL \
    | sed -e "s/LOCALHOSTNAME/$LOCALHOSTNAME/g" \
	  -e "s;PCP_LOG_DIR;$PCP_LOG_DIR;g" \
    | while read host socks logfile args
do
    logfile=`_unsymlink_path $logfile`
    line=`expr $line + 1`
    case "$host"
    in
	\#*|'')	# comment or empty
		continue
		;;
	\$*)	# in-line variable assignment
		$SHOWME && echo "# $host $socks $logfile $args"
		cmd=`echo "$host $socks $logfile $args" \
		     | sed -n \
			 -e "/='/s/\(='[^']*'\).*/\1/" \
			 -e '/="/s/\(="[^"]*"\).*/\1/' \
			 -e '/=[^"'"'"']/s/[;&<>|].*$//' \
			 -e '/^\\$[A-Za-z][A-Za-z0-9_]*=/{
s/^\\$//
s/^\([A-Za-z][A-Za-z0-9_]*\)=/export \1; \1=/p
}'`
		if [ -z "$cmd" ]
		then
		    # in-line command, not a variable assignment
		    _warning "in-line command is not a variable assignment, line ignored"
		else
		    case "$cmd"
		    in
			'export PATH;'*)
			    _warning "cannot change \$PATH, line ignored"
			    ;;
			'export IFS;'*)
			    _warning "cannot change \$IFS, line ignored"
			    ;;
			*)
			    $SHOWME && echo "+ $cmd"
			    eval $cmd
			    ;;
		    esac
		fi
		continue
		;;
    esac

    if [ -z "$socks" -o -z "$logfile" -o -z "$args" ]
    then
	_error "insufficient fields in control file record"
	continue
    fi

    [ $VERY_VERBOSE = "true" ] && echo "Check pmie -h $host -l $logfile ..."

    # make sure output directory exists
    #
    dir=`dirname $logfile`
    if [ ! -d $dir ]
    then
	mkdir -p $dir >$tmp.err 2>&1
	if [ ! -d $dir ]
	then
	    cat $tmp.err
	    _error "cannot create directory ($dir) for pmie log file"
	fi
    fi
    [ ! -d $dir ] && continue

    cd $dir
    dir=`$PWDCMND`
    $SHOWME && echo "+ cd $dir"

    if [ ! -w $dir ]
    then
	_warning "no write access in $dir, skip lock file processing"
	ls -ld $dir
    else
	_lock
    fi

    # match $logfile and $fqdn from control file to running pmies
    pid=""
    fqdn=`pmhostname $host`
    for file in $PCP_TMP_DIR/pmie/[0-9]*
    do
	[ "$file" = "$PCP_TMP_DIR/pmie/[0-9]*" ] && continue
	$VERY_VERBOSE && $PCP_ECHO_PROG $PCP_ECHO_N "... try $file: ""$PCP_ECHO_C"

	p_id=`echo $file | sed -e 's,.*/,,'`
	p_logfile=""
	p_pmcd_host=""

	# throw away stderr in case $file has been removed by now
	eval `tr '\0' '\012' < $file 2>/dev/null | sed -e '/^$/d' | sed -e 3q \
	| $PCP_AWK_PROG '
NR == 2	{ printf "p_logfile=\"%s\"\n", $0; next }
NR == 3	{ printf "p_pmcd_host=\"%s\"\n", $0; next }
	{ next }'`

	p_logfile=`_unsymlink_path $p_logfile`
	if [ "$p_logfile" != $logfile ]
	then
	    $VERY_VERBOSE && echo "different logfile, skip"
	elif [ "$p_pmcd_host" != "$fqdn" ]
	then
	    $VERY_VERBOSE && echo "different host, skip"
	elif _get_pids_by_name pmie | grep "^$pid\$" >/dev/null
	then
	    $VERY_VERBOSE && echo "pmie process $p_id identified, OK"
	    pid=$p_id
	    break
	else
	    $VERY_VERBOSE && echo "pmie process $p_id not running, skip"
	fi
    done

    if [ -z "$pid" -a $START_PMIE = true ]
    then
	configfile=`echo $args | sed -n -e 's/^/ /' -e 's/[ 	][ 	]*/ /g' -e 's/-c /-c/' -e 's/.* -c\([^ ]*\).*/\1/p'`
	if [ ! -z "$configfile" ]
	then
	    # if this is a relative path and not relative to cwd,
	    # substitute in the default pmie search location.
	    #
	    if [ ! -f "$configfile" -a "`basename $configfile`" = "$configfile" ]
	    then
		configfile="$PCP_VAR_DIR/config/pmie/$configfile"
	    fi

	    if [ -f $configfile ]
	    then
		# look for "magic" string at start of file
		#
		if sed 1q $configfile | grep '^#pmieconf-rules [0-9]' >/dev/null
		then
		    # pmieconf file, see if re-generation is needed
		    # Note that pmieconf is in the pcp-pro product (not open source)
		    #
		    cp $configfile $tmp.pmie
		    if $have_pmieconf
		    then
			if pmieconf -f $tmp.pmie $CONFARGS >$tmp.diag 2>&1
			then
			    grep -v "generated by pmieconf" $configfile >$tmp.old
			    grep -v "generated by pmieconf" $tmp.pmie >$tmp.new
			    if diff $tmp.old $tmp.new >/dev/null
			    then
				:
			    else
				if [ -w $configfile ]
				then
				    $VERBOSE && echo "Reconfigured: \"$configfile\" (pmieconf)"
				    eval $CP $tmp.pmie $configfile
				else
				    _warning "no write access to pmieconf file \"$configfile\", skip reconfiguration"
				    ls -l $configfile
				fi
			    fi
			else
			    _warning "pmieconf failed to reconfigure \"$configfile\""
			    cat "s;$tmp.pmie;$configfile;g" $tmp.diag
			    echo "=== start pmieconf file ==="
			    cat $tmp.pmie
			    echo "=== end pmieconf file ==="
			fi
		    fi
		fi
	    else
		# file does not exist, generate it, if possible
		# Note that pmieconf is in the pcp-pro product (not open source)
		# 
		if $have_pmieconf
		then
		    if pmieconf -f $configfile $CONFARGS >$tmp.diag 2>&1
		    then
			:
		    else
			_warning "pmieconf failed to generate \"$configfile\""
			cat $tmp.diag
			echo "=== start pmieconf file ==="
			cat $configfile
			echo "=== end pmieconf file ==="
		    fi
		fi
	    fi
	fi

	args="-h $host -l $logfile $args"

	$VERBOSE && _message restart
	sock_me=''
	if [ "$socks" = y ] 
	then
	    # only check for pmsocks if it's specified in the control file
	    have_pmsocks=false
	    if which pmsocks >/dev/null 2>&1
	    then
		# check if pmsocks has been set up correctly
		if pmsocks ls >/dev/null 2>&1
		then
		    have_pmsocks=true
		fi
	    fi

	    if $have_pmsocks
	    then
		sock_me="pmsocks "
	    else
		echo "$prog: Warning: no pmsocks available, would run without"
		sock_me=""
	    fi
	fi

	[ -f $logfile ] && eval $MV -f $logfile $logfile.prior

	if $SHOWME
	then
	    $VERBOSE && echo
	    echo "+ ${sock_me}$PMIE -b $args"
	    _unlock
	    continue
	else
	    # since this is launched as a sort of daemon, any output should
	    # go on pmie's stderr, i.e. $logfile ... use -b for this
	    #
	    $VERY_VERBOSE && ( echo; $PCP_ECHO_PROG $PCP_ECHO_N "+ ${sock_me}$PMIE -b $args""$PCP_ECHO_C"; echo "..." )
	    pmpost "start pmie from $prog for host $host"
	    ${sock_me}$PMIE -b $args &
	    pid=$!
	fi

	# wait for pmie to get started, and check on its health
	_check_pmie $pid

    elif [ ! -z "$pid" -a $START_PMIE = false ]
    then
	# Send pmie a SIGTERM, which is noted as a pending shutdown.
	# Add pid to list of pmies sent SIGTERM - may need SIGKILL later.
	#
	$VERY_VERBOSE && echo "+ $KILL -TERM $pid"
	eval $KILL -TERM $pid
	$PCP_ECHO_PROG $PCP_ECHO_N "$pid ""$PCP_ECHO_C" >> $tmp.pmies	
    fi

    _unlock
done

# check all the SIGTERM'd pmies really died - if not, use a bigger hammer.
# 
if $SHOWME
then
    :
elif [ $START_PMIE = false -a -s $tmp.pmies ]
then
    pmielist=`cat $tmp.pmies`
    if ps -p "$pmielist" >/dev/null 2>&1
    then
	$VERY_VERBOSE && ( echo; $PCP_ECHO_PROG $PCP_ECHO_N "+ $KILL -KILL `cat $tmp.pmies` ...""$PCP_ECHO_C" )
	eval $KILL -KILL $pmielist >/dev/null 2>&1
	sleep 3		# give them a chance to go
	if ps -f -p "$pmielist" >$tmp.alive 2>&1
	then
	    echo "$prog: Error: pmie process(es) will not die"
	    cat $tmp.alive
	    status=1
	fi
    fi
fi

[ -f $tmp.err ] && status=1
exit
