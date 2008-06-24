#! /bin/sh
#
# Copyright (c) 1995-2000,2003 Silicon Graphics, Inc.  All Rights Reserved.
# Portions Copyright (c) 2007 Aconex.  All Rights Reserved.
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
# Example daily administrative script for pmie logfiles
#

# Get standard environment
. $PCP_DIR/etc/pcp.env

# Get the portable PCP rc script functions
if [ -f $PCP_SHARE_DIR/lib/rc-proc.sh ] ; then
    . $PCP_SHARE_DIR/lib/rc-proc.sh
fi

# added to handle problem when /var/log/pcp is a symlink, as first
# reported by Micah_Altman@harvard.edu in Nov 2001
#
_unsymlink_path()
{
    [ -z "$1" ] && return
    __d=`dirname $1`
    __real_d=`cd $__d 2>/dev/null && /bin/pwd`
    if [ -z "$__real_d" ]
    then
	echo $1
    else
	echo $__real_d/`basename $1`
    fi
}

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
# file to reflect your local configuration (see also -c option below)
#
CONTROL=$PCP_PMIECONTROL_PATH

# default number of days to keep pmie logfiles
#
CULLAFTER=14

# default compression program
#
COMPRESS=bzip2
COMPRESSAFTER=""
COMPRESSREGEX=".meta$|.index$|.Z$|.gz$|.bz2$|.zip$"

# mail addresses to send daily logfile summary to
#
MAILME=""
MAIL=Mail

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

_usage()
{
    cat - <<EOF
Usage: $prog [options]

Options:
  -c control    pmie control file
  -k discard    remove logfiles after "discard" days
  -N            show-me mode, no operations performed
  -V            verbose output
  -x compress   compress log files after "compress" days
  -X program    use program for log file compression
  -Y regex      egrep filter for files not to compress ["$COMPRESSREGEX"]
EOF
    status=1
    exit
}

# option parsing
#
SHOWME=false
RM=rm
KILL=kill
VERBOSE=false
VERY_VERBOSE=false
MYARGS=""

while getopts c:k:m:NVx:X:Y:? c
do
    case $c
    in
	c)	CONTROL="$OPTARG"
		;;
	k)	CULLAFTER="$OPTARG"
		check=`echo "$CULLAFTER" | sed -e 's/[0-9]//g'`
		if [ ! -z "$check" -a X"$check" != Xforever ]
		then
		    echo "Error: -k option ($CULLAFTER) must be numeric"
		    status=1
		    exit
		fi
		;;
	m)	MAILME="$OPTARG"
		;;
	N)	SHOWME=true
		RM="echo + rm"
		KILL="echo + kill"
		MYARGS="$MYARGS -N"
		;;
	V)	if $VERBOSE
		then
		    VERY_VERBOSE=true
		else
		    VERBOSE=true
		fi
		MYARGS="$MYARGS -V"
		;;
	x)	COMPRESSAFTER="$OPTARG"
		check=`echo "$COMPRESSAFTER" | sed -e 's/[0-9]//g'`
		if [ ! -z "$check" ]
		then
		    echo "Error: -x option ($COMPRESSAFTER) must be numeric"
		    status=1
		    exit
		fi
		;;
	X)	COMPRESS="$OPTARG"
		;;
	Y)	COMPRESSREGEX="$OPTARG"
		;;
	?)	_usage
		;;
    esac
done
shift `expr $OPTIND - 1`

[ $# -ne 0 ] && _usage

if [ ! -f $CONTROL ]
then
    echo "$prog: Error: cannot find control file ($CONTROL)"
    status=1
    exit
fi

SUMMARY_LOGNAME=`pmdate -1d %Y%m%d`

_error()
{
    _report Error "$1"
}

_warning()
{
    _report Warning "$1"
}

_report()
{
    echo "$prog: $1: $2"
    echo "[$CONTROL:$line] ... inference engine for host \"$host\" unchanged"
    touch $tmp.err
}

_unlock()
{
    rm -f lock
    echo >$tmp.lock
}

# filter for pmie log files in working directory -
# pass in the number of days to skip over (backwards) from today
#
# pv:821339 too many sed commands for IRIX ... split into groups
#           of at most 200 days
#
_date_filter()
{
    # start with all files whose names match the patterns used by
    # the PCP pmie log file management scripts ... this list may be
    # reduced by the sed filtering later on
    #
    ls | sed -n >$tmp.in -e '/[-.][12][0-9][0-9][0-9][0-1][0-9][0-3][0-9]$/p'

    i=0
    while [ $i -le $1 ]
    do
	dmax=`expr $i + 200`
	[ $dmax -gt $1 ] && dmax=$1
	echo "/[-.][12][0-9][0-9][0-9][0-1][0-9][0-3][0-9]$/{" >$tmp.sed1
	while [ $i -le $dmax ]
	do
	    x=`pmdate -${i}d %Y%m%d`
	    echo "/[-.]$x\$/d" >>$tmp.sed1
	    i=`expr $i + 1`
	done
	echo "p" >>$tmp.sed1
	echo "}" >>$tmp.sed1

	# cull file names with matching dates, keep other file names
	#
	sed -n -f $tmp.sed1 <$tmp.in >$tmp.tmp
	mv $tmp.tmp $tmp.in
    done

    cat $tmp.in
}


rm -f $tmp.err $tmp.mail
line=0
version=''
cat $CONTROL \
| sed -e "s/LOCALHOSTNAME/$LOCALHOSTNAME/g" \
      -e "s;PCP_LOG_DIR;$PCP_LOG_DIR;g" \
| while read host socks logfile args
do
    logfile=`_unsymlink_path $logfile`
    line=`expr $line + 1`
    $VERY_VERBOSE && echo "[control:$line] host=\"$host\" socks=\"$socks\" log=\"$logfile\" args=\"$args\""
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

    if $VERY_VERBOSE
    then
	echo "Check pmie -h $host ... in $dir ..."
    fi

    dir=`dirname $logfile`
    if [ ! -d "$dir" ]
    then
	_error "logfile directory ($dir) does not exist"
	continue
    fi

    cd $dir
    dir=`$PWDCMND`
    $SHOWME && echo "+ cd $dir"

    if $VERBOSE
    then
	echo
	echo "=== daily maintenance of pmie log files for host $host ==="
	echo
    fi

    if [ ! -w $dir ]
    then
	echo "$prog: Warning: no write access in $dir, skip lock file processing"
    else
	# demand mutual exclusion
	#
	fail=true
	rm -f $tmp.stamp
	for try in 1 2 3 4
	do
	    if pmlock -v lock >$tmp.out
	    then
		echo $dir/lock >$tmp.lock
		fail=false
		break
	    else
		if [ ! -f $tmp.stamp ]
		then
		    touch -t `pmdate -30M %Y%m%d%H%M` $tmp.stamp
		fi
		if [ ! -z "`find lock -newer $tmp.stamp -print 2>/dev/null`" ]
		then
		    :
		else
		    echo "$prog: Warning: removing lock file older than 30 minutes"
		    LC_TIME=POSIX ls -l $dir/lock
		    rm -f lock
		fi
	    fi
	    sleep 5
	done

	if $fail
	then
	    # failed to gain mutex lock
	    #
	    if [ -f lock ]
	    then
		echo "$prog: Warning: is another PCP cron job running concurrently?"
		LC_TIME=POSIX ls -l $dir/lock
	    else
		echo "$prog: `cat $tmp.out`"
	    fi
	    _warning "failed to acquire exclusive lock ($dir/lock) ..."
	    continue
	fi
    fi

    # match $logfile and $fqdn from control file to running pmies
    pid=""
    fqdn=`pmhostname $host`
    for file in `ls $PCP_TMP_DIR/pmie`
    do
	p_id=$file
	file="$PCP_TMP_DIR/pmie/$file"
	p_logfile=""
	p_pmcd_host=""

	case "$PCP_PLATFORM"
	in
	    irix)
		test -f /proc/pinfo/$p_id
		;;
	    *)
		test -e /proc/$p_id
		;;
	esac
	if [ $? -eq 0 ]
	then
	    eval `tr '\0' '\012' < $file | sed -e '/^$/d' | sed -e 3q | $PCP_AWK_PROG '
NR == 2	{ printf "p_logfile=\"%s\"\n", $0; next }
NR == 3	{ printf "p_pmcd_host=\"%s\"\n", $0; next }
	{ next }'`
	    p_logfile=`_unsymlink_path $p_logfile`
	    if [ "$p_logfile" = $logfile -a "$p_pmcd_host" = "$fqdn" ]
	    then
		pid=$p_id
		break
	    fi
	else
	    # ignore, its not a running process
	    eval $RM -f $file
	fi
    done

    if [ -z "$pid" ]
    then
	_error "no pmie instance running for host \"$host\""
    else
	if [ "`echo $pid | wc -w`" -gt 1 ]
	then
	    _error "multiple pmie instances running for host \"$host\", processes: $pid"
	    _unlock
	    continue
	fi

	# now move current logfile name aside and SIGHUP to "roll the logs"
	# creating a new logfile with the old name in the process.
	#
	$SHOWME && echo "+ mv $logfile ${logfile}.{SUMMARY_LOGNAME}"
	if mv $logfile ${logfile}.${SUMMARY_LOGNAME}
	then
	    $VERY_VERBOSE && echo "+ $KILL -HUP $pid"
	    eval $KILL -HUP $pid
	    echo ${logfile}.${SUMMARY_LOGNAME} >> $tmp.mail
	else
	    _error "problems moving logfile \"$logfile\" for host \"$host\""
	    touch $tmp.err
	fi
    fi

    # and cull old logfiles
    #
    if [ X"$CULLAFTER" != X"forever" ]
    then
	_date_filter $CULLAFTER >$tmp.list
	if [ -s $tmp.list ]
	then
	    if $VERBOSE
	    then
		echo "Log files older than $CULLAFTER days being removed ..."
		fmt <$tmp.list | sed -e 's/^/    /'
	    fi
	    if $SHOWME
	    then
		cat $tmp.list | xargs echo + rm -f
	    else
		cat $tmp.list | xargs rm -f
	    fi
	fi
    fi

    # finally, compress old log files
    # (after cull - don't compress unnecessarily)
    #
    if [ ! -z "$COMPRESSAFTER" ]
    then
	_date_filter $COMPRESSAFTER | egrep -v "$COMPRESSREGEX" >$tmp.list
	if [ -s $tmp.list ]
	then
	    if $VERBOSE
	    then
		echo "Log files older than $COMPRESSAFTER days being compressed ..."
		fmt <$tmp.list | sed -e 's/^/    /'
	    fi
	    if $SHOWME
	    then
		cat $tmp.list | xargs echo + $COMPRESS
	    else
		cat $tmp.list | xargs $COMPRESS
	    fi
	fi
    fi

    _unlock

done

if [ -n "$MAILME" -a -s $tmp.mail ]
then
    logs=""
    for file in `cat $tmp.mail`
    do
	[ -f $file ] && logs="$logs $file"
    done
    grep -v ' OK ' $logs | $MAIL -s "PMIE summary for $LOCALHOSTNAME" $MAILME
    rm -f $tmp.mail
fi

[ -f $tmp.err ] && status=1
exit
