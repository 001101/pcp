/*
 * Copyright (c) 2000,2003,2004 Silicon Graphics, Inc.  All Rights Reserved.
 * 
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation; either version 2 of the License, or (at your
 * option) any later version.
 * 
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
 * or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
 * for more details.
 * 
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, write to the Free Software Foundation, Inc.,
 * 59 Temple Place, Suite 330, Boston, MA  02111-1307 USA
 * 
 * Contact information: Silicon Graphics, Inc., 1500 Crittenden Lane,
 * Mountain View, CA 94043, USA, or: http://www.sgi.com
 */

#include "pmapi.h"
#include "impl.h"
#include "pmda.h"
#include <ctype.h>
#include <sys/ioctl.h>
#ifdef HAVE_SYS_TERMIOS_H
#include <sys/termios.h>
#endif

struct statsrc_t {
    int		ctx;
    int		flip;
    char	* sname;
    pmID	* pmids;
    pmDesc	* pmdesc;
    pmResult	* res[2];
};

char *pmProgname;

static char * metrics[] = {
#define LOADAVG 0
    "kernel.all.load",   
#define MEM 1
    "swap.used",            
    "mem.util.free",        
    "mem.util.bufmem",      
    "mem.util.cached",      
#define SWAP 5
    "swap.pagesin",              
    "swap.pagesout",             
#define IO 7
    "disk.all.blkread",     
    "disk.all.blkwrite",    
#define SYSTEM 9
    "kernel.all.intr",      
    "kernel.all.pswitch",   
#define CPU 11
    "kernel.all.cpu.nice",  
    "kernel.all.cpu.user",  
    "kernel.all.cpu.sys",
    "kernel.all.cpu.idle",
};

static char * metricSubst[] = {
    NULL,
/*Memory*/
    NULL,
    NULL,
    "mem.bufmem",
    NULL,
/*Swap*/
    "swap.in",              
    "swap.out",             
/*IO*/
    NULL,
    NULL,
/*System*/
    "kernel.all.intr.non_vme", /* We don't expect VME in the new systems */
    NULL,
/*CPU*/
    NULL,
    NULL,
    NULL,
    NULL
};

static const int nummetrics = sizeof(metrics)/sizeof (metrics[0]);

static char swap_op ='p';

long long cntDiff(pmDesc * d, pmValueSet * now, pmValueSet * was)
{
    long long diff;
    pmAtomValue a;
    pmAtomValue b;

    pmExtractValue (was->valfmt,  &was->vlist[0], d->type, &a, d->type);
    pmExtractValue (now->valfmt,  &now->vlist[0], d->type, &b, d->type);

    switch (d->type) {
    case PM_TYPE_32:
	diff = b.l - a.l;
	break;

    case PM_TYPE_U32:
	diff = b.ul - a.ul;
	break;

    case PM_TYPE_U64:
	diff = b.ull - a.ull;
	break;
    }

    return (diff);
}

struct statsrc_t *
getNewContext (int type, char * host)
{
    struct statsrc_t * s;

    if ((s = (struct statsrc_t *)malloc(sizeof (struct statsrc_t))) != NULL) {
	if ((s->ctx = pmNewContext (type, host)) < 0 ) {
	    fprintf(stderr, 
		    "%s: Cannot create context to get data from %s: %s\n",
		    pmProgname, host, pmErrStr(s->ctx));
	    free (s);
	    s = NULL;
	} else {
	    int sts;
	    int i;
	    
	    if ((s->pmids = calloc (nummetrics, sizeof (pmID))) == NULL) {
		free (s);
		return (NULL);
	    }

	    if ((sts = pmLookupName(nummetrics, metrics, s->pmids)) < 0) {
		if (sts == PM_ERR_NAME || sts == PM_ERR_NONLEAF) {
		    for (i = 0; i < nummetrics; i++) {
			if (s->pmids[i] != PM_ID_NULL) {
			    continue;
			}
			
			if (metricSubst[i] == NULL) {
			    fprintf(stderr, 
				    "%s: %s: no metric \"%s\": %s\n",
				    pmProgname, host, metrics[i],
				    pmErrStr(sts));
			} else {
			    int e2 = pmLookupName(1,metricSubst+i, s->pmids+i);
			    if ( e2 < 0 ) {
				fprintf (stderr,
					 "%s: %s: no metric \"%s\" nor \"%s\": %s\n",
					 pmProgname, host, metrics[i], 
					 metricSubst[i], pmErrStr(e2));
			    }
			    else {
				fprintf (stderr,
					 "%s: %s: Warning: using metric \"%s\" instead of \"%s\"\n",
					 pmProgname, host,
					 metricSubst[i], metrics[i]);
				if (i == SWAP || i == SWAP+1)
				    swap_op = 's';
			    }
			}
		    }
		} else {
		    free (s->pmids);
		    free (s);
		    return (NULL);
		}
	    }
	    
	    if ((s->pmdesc = calloc (nummetrics, sizeof (pmDesc))) == NULL) {
		free (s->pmids);
		free (s);
		return (NULL);
	    }

	    for (i = 0; i < nummetrics; i++) {
		if (s->pmids[i] == PM_ID_NULL) {
		    s->pmdesc[i].indom = PM_INDOM_NULL;
		    s->pmdesc[i].pmid = PM_ID_NULL;
		} else {
		    if ((sts = pmLookupDesc(s->pmids[i], s->pmdesc+i)) < 0) {
			fprintf(stderr, 
				"%s: %s: Warning: cannot retrieve description for "
				"metric \"%s\" (PMID: %s)\nReason: %s\n",
				pmProgname, host, metrics[i], pmIDStr(s->pmids[i]),
				pmErrStr(sts));
			s->pmdesc[i].indom = PM_INDOM_NULL;
			s->pmdesc[i].pmid = PM_ID_NULL;
			
		    }
		}
	    }

	    s->flip = 0;
	    s->res[0] = s->res[1] = NULL;
	}
    }

    return (s);
}

void
destroyContext (struct statsrc_t * s) 
{
    if ( s != NULL && s->ctx >= 0 ) {
	if ((s->sname = strdup (pmGetContextHostName (s->ctx))) == NULL) {
	    fprintf (stderr, "%s: bad luck - cannot save context name.\n",
		     pmProgname);
	    exit (1);
	}

	pmDestroyContext(s->ctx);
	s->ctx = -1;
	free (s->pmdesc);
	s->pmdesc = NULL;
	free (s->pmids);
	s->pmids = NULL;
	if ( s->res[1-s->flip] != NULL ) {
	    pmFreeResult (s->res[1-s->flip]);
	}
	s->res[1-s->flip] = NULL;
    }
}

static void
scale_n_print(long value)
{
    if (value < 10000)
	printf (" %4ld", value);
    else {
	value /= 1000;	/* '000s */
	if (value < 1000)
	    printf(" %3ldK", value);
	else {
	    value /= 1000;	/* '000,000s */
	    printf(" %3ldM", value);
	}
    }
}

int 
main(int argc, char *argv[]) 
{
    int tzh = -1;
    struct timeval start;
    struct timeval finish;
    struct timeval point0;

    struct statsrc_t * pd;
    struct statsrc_t ** ctxList = & pd;

    char * msg;

    int ctxCnt = 0;
    int ctxType = 0;
    char * nsFile = PM_NS_DEFAULT;
    int c;
    int pauseFlag = 0;
    int errflag = 0;
    int j;
    int samples = 0;
    int iter;
    struct timeval tv;
    char * endnum;
    struct winsize win;
    int rows = 21;
    char ** namelst = 0;
    int namecnt;
    time_t now;

    int printTail = 0;
    int zflag = 0;
    char * tz = NULL;
    int allcnt = (argc-1)/2;

    struct timespec sleeptime = {5, 0};
    
    char * Tflag = NULL,
	* Aflag = NULL,
	* Sflag = NULL,
	* Oflag = NULL;

    float period;

    setlinebuf(stdout);
    pmProgname = basename(argv[0]);

    namecnt = 0;
    if ( argc > 2 ) {
	if ((namelst = (char **)calloc(allcnt, sizeof(char *))) == NULL) {
	    fprintf (stderr, "%s: out of memory!\n", pmProgname);
	    exit (2);
	}
    }

    while ((c = getopt(argc, argv, "A:a:D:h:H:lLn:O:ps:S:t:T:zZ:?")) != EOF) {
	switch (c) {
	case 'A':	/* sample time alignment */
	    Aflag = optarg;
	    break;

	case 'a':	/* treat names as archive names */
	    if ( ctxType && (ctxType != PM_CONTEXT_ARCHIVE)) {
		fprintf (stderr, 
			 "%s: you cannot mix archives and %s together\n",
			 pmProgname,
			 (ctxType == PM_CONTEXT_HOST)? "hosts":"local");
		errflag++;
	    } else {
		ctxType = PM_CONTEXT_ARCHIVE;
		namelst[namecnt++] = optarg;
	    }
	    break;


	case 'D':	/* debug flag */
	    if ((j = __pmParseDebug(optarg)) < 0) {
		fprintf(stderr, 
			"%s: unrecognized debug flag specification (%s)\n",
			pmProgname, optarg);
		errflag++;
	    }
	    else
		pmDebug |= j;
	    break;

	case 'H': /* Read hosts from the file */
	    if ( ctxType && (ctxType != PM_CONTEXT_HOST)) {
		fprintf (stderr,
			 "%s: you cannot mix hosts and %s together\n",
			 pmProgname,
			 (ctxType == PM_CONTEXT_ARCHIVE)? "archives":"local");
		errflag++;
	    } else {
		FILE * hl;

		ctxType = PM_CONTEXT_HOST;
		if ( (hl = fopen (optarg, "r")) != NULL ) {
		    char s[128];
		    while ( fgets (s, 127, hl) != NULL ) {
			char * p = s;
			while ( isspace ((int)*p) && *p != '\n' ) p++;
			if ( *p != '\n' && *p != '#' ) {
			    char * ns = p;
			    if ( allcnt <= namecnt+1 ) {
				allcnt *= 2;
				namelst=(char **)realloc(namelst, 
							 allcnt*sizeof(char*));
				if ( namelst == NULL) {
				    fprintf (stderr, "%s: out of memory!\n",
					     pmProgname);
				    exit (2);
				}
			    }
			
			    while ( *p != '\n' && *p != '#' &&
				    ! isspace ((int)*p)) p++;

			    *p = '\0';
			    if ((namelst[namecnt++] = strdup (ns)) == NULL ) {
				fprintf (stderr, "%s: memory exhausted!\n",
					 pmProgname);
				exit (2);
			    }
			}
		    }

		    fclose (hl);
		} else {
		    fprintf (stderr, "%s: cannot open %s - %s\n",
			     pmProgname, optarg, strerror (errno));
		    errflag++;
		}
	    }
	    break;

	case 'h':
	    if ( ctxType && (ctxType != PM_CONTEXT_HOST)) {
		fprintf (stderr,
			 "%s: you cannot mix hosts and %s together\n",
			 pmProgname,
			 (ctxType == PM_CONTEXT_ARCHIVE)? "archives":"local");
		errflag++;
	    } else {
		ctxType = PM_CONTEXT_HOST;
		if ( allcnt <= namecnt+1 ) {
		    allcnt *= 2;
		    namelst = (char **)realloc(namelst, allcnt*sizeof(char *));
		    if ( namelst == NULL) {
			fprintf (stderr, "%s: out of memory!\n",
				 pmProgname);
			exit (2);
		    }
		}

		namelst[namecnt++] = optarg;
	    }
	    break;

	case 'l':
	    printTail++;
	    break;

	case 'L':	/* standalone, no PMCD */
	    if (ctxType) {
		fprintf(stderr, "%s: -a, -h and -L are mutually exclusive\n",
			pmProgname);
		errflag++;
	    } else {
		ctxType = PM_CONTEXT_LOCAL;
	    }
	    break;

	case 'n':	/* alternative name space file */
	    nsFile = optarg;
	    break;

	case 'p':	/* pause between updates when replaying an archive */
	    pauseFlag++;
	    break;

	case 's':	/* sample count */
	    if (Tflag) {
		fprintf(stderr, 
			"%s: at most one of -T and -s allowed\n", pmProgname);
		errflag++;
	    } else {
		char * endnum;
		samples = (int)strtol(optarg, &endnum, 10);
		if (*endnum != '\0' || samples < 0) {
		    fprintf(stderr, 
			    "%s: -s requires numeric argument\n", pmProgname);
		    errflag++;
		}
	    }
	    break;

	case 't':	/* update interval */
	    if (pmParseInterval(optarg, &tv, &endnum) < 0) {
		fprintf(stderr, 
			"%s: -t argument not in pmParseInterval(3) format:\n",
			pmProgname);
		fprintf(stderr, "%s\n", endnum);
		free(endnum);
		errflag++;
	    } else {
		sleeptime.tv_sec = tv.tv_sec;
		sleeptime.tv_nsec = tv.tv_usec * 1000;
	    }
		
	    break;
		
	case 'O':	/* time window offset */
	    Oflag = optarg;
	    break;

	    
	case 'S':	/* time window start */
	    Sflag = optarg;
	    break;

	    
	case 'T':	/* time window end */
	    if (samples) {
		fprintf(stderr, "%s: at most one of -T and -s allowed\n",
			pmProgname);
		errflag++;
	    }
	    Tflag = optarg;
	    break;

	case 'z':	/* timezone from host */
	    if (tz != NULL) {
		fprintf(stderr, "%s: at most one of -Z and/or -z allowed\n",
			pmProgname);
		errflag++;
	    }
	    zflag++;
	    break;

	case 'Z':	/* $TZ timezone */
	    if (zflag) {
		fprintf(stderr, "%s: at most one of -Z and/or -z allowed\n",
			pmProgname);
		errflag++;
	    }
	    tz = optarg;
	    break;

	case '?':
	default:
	    errflag++;
	    break;
	}
    }

    if ( argc != optind ) {
	fprintf (stderr, "%s: too many options\n", pmProgname);
	errflag++;
    }

    if (pauseFlag && (ctxType != PM_CONTEXT_ARCHIVE)) {
	fprintf(stderr, "%s: -p can only be used with -a\n", pmProgname);
	errflag++;
    }

    if ((ctxType != PM_CONTEXT_ARCHIVE) && 
	(Oflag != NULL || Sflag != NULL || Aflag != NULL) ) {
	fprintf (stderr, "%s: -S, -O and -A are supported for archives only\n",
		 pmProgname);
	errflag++;
    }

    if (zflag && (ctxType != PM_CONTEXT_ARCHIVE) && 
	(ctxType != PM_CONTEXT_HOST)) {
	fprintf(stderr, "%s: -z requires an explicit -a or -h option\n",
		pmProgname);
	errflag++;
    }

    if (errflag) {
	fprintf(stderr,
		"Usage: %s [options]\n\n"
		"Options:\n"
		"  -A align	align sample times on natural boundaries\n"
		"  -a name	read metrics from PCP log archive\n"
		"  -l		print last 7 charcters of the host name\n"
		"  -L		use standalone connection to localhost\n"
		"  -h name	read metrics from PMCD on named host\n"
		"  -H file	read host's names from the file\n"
		"  -n pmnsfile	use an alternative PMNS\n"
		"  -O offset	initial offset into the time window\n"
		"  -p		pause between updates for archive replay\n"
		"  -S starttime	start of the time window\n"
		"  -s samples	terminate after this many iterations\n"
		"  -t interval	sample interval [default 5 seconds]\n"
		"  -T endtime	end of the time window\n"
		"  -Z timezone	set reporting timezone\n"
		"  -z		set reporting timezone to local time of\n"
		"		metrics source\n"
		, pmProgname);
	exit(1);
    }

    if ( ! ctxType ) { /* Default is to talk to PMCD */
	ctxType = PM_CONTEXT_HOST;
    }

    if (nsFile != PM_NS_DEFAULT) { 
	int sts;
	if ((sts = pmLoadNameSpace(nsFile)) < 0) {
	    printf("%s: Cannot load namespace from \"%s\": %s\n",
		   pmProgname, nsFile, pmErrStr(sts));
	    exit(1);
	}
    }

    period = (sleeptime.tv_sec * 1.0e9 + sleeptime.tv_nsec ) / 1e9;

    if (namecnt) {
	if ((ctxList = calloc (namecnt, sizeof(struct statsrc_t *))) != NULL) {
	    int ct;
	    double early = INT_MAX;
	    double late = 0;

	    for (ct=0; ct < namecnt; ct++ ) {
		if ((pd = getNewContext (ctxType, namelst[ct])) != NULL) {
		    int sts;

		    /* tzh is used as an initialization flag */
		    if ( tzh < 0 ) {
			if (zflag) {
			    if ((tzh = pmNewContextZone()) < 0) {
				fprintf(stderr, 
					"%s: Cannot set context timezone:%s\n",
					pmProgname, pmErrStr(tzh));
				exit(1);
			    }
			    printf("Note: timezone set to local timezone of "
				   "host \"%s\"\n\n",
				   pmGetContextHostName(pd->ctx));
			}
			else if (tz != NULL) {
			    if ((tzh = pmNewZone(tz)) < 0) {
				fprintf(stderr, 
					"%s: Cannot set timezone to '%s':%s\n",
					pmProgname, tz, pmErrStr(tzh));
				exit(1);
			    }
			    printf("Note: timezone set to \"TZ=%s\"\n\n", tz);
			}
			else {
			    tzh = pmNewContextZone();
			}
		    }

		    pmUseZone (tzh);

		    /* If we're dealing with archives, find the one
                     * which starts first */
		    if ( ctxType == PM_CONTEXT_ARCHIVE ) {
			pmLogLabel label;
			struct timeval f;

			if ((sts = pmGetArchiveLabel(&label)) < 0) {
			    fprintf(stderr, 
				    "%s: Cannot get archive label record:%s\n",
				    pmProgname, pmErrStr(sts));
			    exit(1);
			}

			if ( early > (label.ll_start.tv_sec*1e6 + 
				      label.ll_start.tv_usec)/1e6 ) {
			    start = label.ll_start;
			    early = (label.ll_start.tv_sec*1e6 + 
				     label.ll_start.tv_usec) / 1e6;
			}

			if ((sts = pmGetArchiveEnd(&f)) < 0) {
			    fprintf(stderr, 
				    "%s: Cannot determine end of archive: %s",
				    pmProgname, pmErrStr(sts));
			    exit(1);
			}

			if ( late < (f.tv_sec*1e6 + f.tv_usec)/1e6 ) {
			    finish = f;
			    late =  (f.tv_sec*1e6 + f.tv_usec)/1e6;
			}
		    } else {
			if ( ! ct ) {
			    gettimeofday (&start, NULL);
			    finish.tv_sec = INT_MAX;
			    finish.tv_usec = 0;
			}
		    }

		    ctxList[ctxCnt++] = pd;
		}
	    }
	} else {
	    fprintf (stderr, "%s: out of memory!\n", pmProgname);
	    exit (1);
	}

	if ( ! ctxCnt ) {
	    fprintf (stderr, "%s: No place to get data from!\n", pmProgname);
	    exit(1);

	}
    } else {
	/* Read metrics from the local host. Note, that ctxType can be 
	 * either PM_CONTEXT_LOCAL or PM_CONTEXT_HOST, but not 
	 * PM_CONTEXT_ARCHIVE */
	char local[MAXHOSTNAMELEN];
	gethostname (local, MAXHOSTNAMELEN);
	local[MAXHOSTNAMELEN-1] = '\0';
	if ((pd = getNewContext (ctxType, local)) == NULL ) {
	    exit (1);
	} else {
	    gettimeofday (&start, NULL);
	    finish.tv_sec = INT_MAX;
	    finish.tv_usec = 0;
	}

	ctxCnt = 1;
    }

    if (ioctl(1, TIOCGWINSZ, &win) != -1 && win.ws_row > 0)
	rows = win.ws_row - 3;


    /* Do first fetch */
    for ( c=0; c < ctxCnt; c++ ) {
	int sts;
	struct statsrc_t * pd = ctxList[c];
	struct timeval rend;
	struct timeval offt;

	pmUseContext (pd->ctx);

	if (pmParseTimeWindow(Sflag, Tflag, Aflag, Oflag, &start, &finish,
			      &point0, &rend, &offt, &msg) < 0) {
	    fprintf(stderr, "%s: %s", pmProgname, msg);
	    destroyContext (pd);
	} else {
	    now = (time_t)(point0.tv_sec + 0.5 + point0.tv_usec / 1.0e6);

	    if (Tflag) {
		double rt = rend.tv_sec - offt.tv_sec + 
		    (rend.tv_usec - offt.tv_usec) / 1e6;

		if ( rt / period > samples ) {
		    samples = (int) (rt/period);
		}
	    }

	    if (ctxType == PM_CONTEXT_ARCHIVE) {
		const int SECS_IN_24_DAYS = 2073600;
		int step;
		int mode;

		if (sleeptime.tv_sec > SECS_IN_24_DAYS) {
		    step = sleeptime.tv_sec;
		    mode = PM_MODE_INTERP|PM_XTB_SET(PM_TIME_SEC);
		} else {
		    step = sleeptime.tv_sec * 1e3 + sleeptime.tv_nsec / 1e6;
		    mode = PM_MODE_INTERP|PM_XTB_SET(PM_TIME_MSEC);
		}
			
		if ((sts = pmSetMode(mode, &point0, step)) < 0) {
		    fprintf(stderr, "%s: pmSetMode failed: %s\n", 
			    pmProgname, pmErrStr(sts));
		    destroyContext (pd);
		} else {
		}
	    }
	}
	
	if ( pd->ctx >= 0 ) {
	    if ((sts = pmFetch(nummetrics, pd->pmids, pd->res+pd->flip)) < 0) {
		pd->res[pd->flip] = NULL;
	    } else {
		pd->flip = 1 - pd->flip;
	    }
	}
    }

    for (iter=0; (samples==0) || (iter < samples); iter++ ) {
	if ( (iter * ctxCnt) % rows < ctxCnt ) {
	    pmResult * r = ctxList[0]->res[1-ctxList[0]->flip];
	    char tbuf[26];

	    if ( r != NULL  ) {
		now = (time_t)(r->timestamp.tv_sec + 0.5 + 
			       r->timestamp.tv_usec/ 1.0e6);
	    }
	    printf ("@ %s", pmCtime (&now, tbuf));

	    if ( ctxCnt > 1 ) {
		printf ("%-7s%8s%21s%10s%10s%10s%12s\n",
			"node", "loadavg","memory","swap","io",
			"system","cpu");
		printf("%8s%7s %6s %6s %6s   %c%1s   %c%1s %4s %4s %4s %4s %3s %3s %3s\n",
		       "", "1 min","swpd","buff","cache",
		       swap_op,"i",swap_op,"o","bi","bo",
		       "in","cs","us","sy","id");

	    } else {
		printf("%8s%28s%10s%10s%10s%12s\n",
		       "loadavg","memory","swap","io","system","cpu");
		printf(" %7s %6s %6s %6s %6s   %c%1s   %c%1s %4s %4s %4s %4s %3s %3s %3s\n",
		       "1 min","swpd","free","buff","cache",
		       swap_op,"i",swap_op,"o","bi","bo",
		       "in","cs","us","sy","id");
	    }
	}

	if ( ctxType != PM_CONTEXT_ARCHIVE  || pauseFlag ) {
#ifdef HAVE_NANOSLEEP
	    nanosleep (&sleeptime, NULL);
#else
#ifdef HAVE_USLEEP
	    usleep((useconds_t)(sleeptime.tv_sec * 1e6 + (sleeptime.tv_nsec + 5e2) / 1e3));
#else
	    sleep((unsigned int)(sleeptime.tv_sec + (sleeptime.tv_nsec + 5e8) / 1e9));
#endif
#endif
	}

	for ( j=0; j < ctxCnt; j++ ) {
	    int sts;
	    int i;
	    unsigned long long dtot = 0;
	    unsigned long long diffs[4];
	    pmAtomValue la;
	    struct statsrc_t * s = ctxList[j];

	    if (ctxCnt > 1 ) {
		const char * fn = (s->ctx < 0 ) ? s->sname : 
		    pmGetContextHostName (s->ctx);
		
		if ( printTail ) {
		    printf ("%-7s", 
			    (strlen (fn) > 7 ) ? fn + strlen (fn) - 7:fn);
		} else {
		    printf ("%-7.7s", fn);
		}

		if ( s->ctx < 0 ) {
		    putchar ('\n');
		    continue;
		}

		pmUseContext (s->ctx);
	    }

	    if ((sts = pmFetch(nummetrics, s->pmids, s->res + s->flip)) < 0) {
		if (ctxType == PM_CONTEXT_HOST && sts == PM_ERR_IPC) {
		    puts (" Fetch failed. Reconnecting ...");
		    if ( s->res[1-s->flip] != NULL ) {
			pmFreeResult(s->res[1-s->flip]);
			s->res[1-s->flip] = NULL;
		    }
		    pmReconnectContext (s->ctx);
		} else if ((ctxType == PM_CONTEXT_ARCHIVE) && 
			   (sts == PM_ERR_EOL) &&
			   (s->res[0] == NULL) && (s->res[1] == NULL)) {
		    /* I'm yet to see smth from this archive - don't
		     * discard it just yet */
		    puts (" No data in the archive");
		} else {
		    int k;
		    int valid = 0;
			
		    printf(" pmFetch: %s\n", pmErrStr(sts));

		    destroyContext (s);
		    for ( k=0; k < ctxCnt; k++ ) {
			valid += (ctxList[k]->ctx >= 0);
		    }
			
		    if ( ! valid ) {
			exit(1);
		    }
		}
	    } else {
		pmResult * cur = s->res[s->flip];
		pmResult * prev = s->res[1 - s->flip];


		/* LoadAvg - Assume that 1min is the first one */
		if (s->pmdesc[LOADAVG].pmid == PM_ID_NULL ||
		    cur->vset[LOADAVG]->numval < 1) 
		    printf (" %7.7s", "?");
		else {
		    pmExtractValue(cur->vset[LOADAVG]->valfmt,
				   &cur->vset[LOADAVG]->vlist[0], 
				   s->pmdesc[LOADAVG].type,
				   &la, PM_TYPE_FLOAT);
		    
		    printf (" %7.2f", la.f);
		}
	    
		/* Memory state */
		for ( i=0; i < 4; i++ ) {
		    if ( i == 2 && ctxCnt > 1 ) 
			continue; /*Don't report free mem for multiple hosts */

		    if (cur->vset[MEM+i]->numval == 1) {
			pmUnits kb =  PMDA_PMUNITS(1, 0, 0, 
						   PM_SPACE_KBYTE, 0, 0);

			pmExtractValue(cur->vset[MEM+i]->valfmt,
				       &cur->vset[MEM+i]->vlist[0], 
				       s->pmdesc[MEM+i].type,
				       &la, PM_TYPE_U32);
			pmConvScale (s->pmdesc[MEM+i].type, & la, 
				     & s->pmdesc[MEM+i].units, &la, &kb);

			if (la.ul < 1000000)
			    printf(" %6u", la.ul);
			else {
			    la.ul /= 1024;	/* PM_SPACE_MBYTE now */
			    if (la.ul < 100000)
				printf(" %5um", la.ul);
			    else {
				la.ul /= 1024;      /* PM_SPACE_GBYTE now */
				printf(" %5ug", la.ul);
			    }
			}
		    } else 
			printf(" %6.6s", "?");
		}

		/* Swap in/out */
		for ( i=0; i < 2; i++ ) {
		    if (s->pmdesc[SWAP+i].pmid == PM_ID_NULL || prev == NULL ||
			prev->vset[SWAP+i]->numval != 1 ||
			cur->vset[SWAP+i]->numval != 1) 
			printf(" %4.4s", "?");
		    else
			scale_n_print(cntDiff(s->pmdesc+SWAP+i, cur->vset[SWAP+i], prev->vset[SWAP+i])/period);
		}

		/* io in/out */
		for ( i=0; i < 2; i++ ) {
		    if (s->pmdesc[IO+i].pmid == PM_ID_NULL || prev == NULL ||
			prev->vset[IO+i]->numval != 1 ||
			cur->vset[IO+i]->numval != 1) 
			printf(" %4.4s", "?");
		    else 
			scale_n_print(cntDiff(s->pmdesc+IO+i, cur->vset[IO+i], prev->vset[IO+i])/period);
		}

		/* system interrupts */
		for ( i=0; i < 2; i++ ) {
		    if (s->pmdesc[SYSTEM+i].pmid == PM_ID_NULL || 
			prev == NULL ||
			prev->vset[SYSTEM+i]->numval != 1 ||
			cur->vset[SYSTEM+i]->numval != 1) 
			printf(" %4.4s", "?");
		    else
			scale_n_print(cntDiff (s->pmdesc+SYSTEM+i, cur->vset[SYSTEM+i], prev->vset[SYSTEM+i])/period);
		}

		/* CPU utilization - report percentage */
		for ( i=0; i < 4; i++ ) {
		    if (s->pmdesc[CPU+i].pmid == PM_ID_NULL || prev == NULL ||
			cur->vset[CPU+i]->numval != 1 ||
			prev->vset[CPU+i]->numval != 1) {
			if ( i ) {
			    break;
			} else { /* Nice is optional */
			    diffs[i] = 0;
			}
		    } else {
			diffs[i] = cntDiff (s->pmdesc+CPU+i,
					    cur->vset[CPU+i],
					    prev->vset[CPU+i]);
			dtot += diffs[i];
		    }
		}

		if ( i != 4 ) {
		    printf(" %3.3s %3.3s %3.3s", "?", "?", "?");
		} else {
		    unsigned long long fill = dtot/2;
		    printf(" %3u %3u %3u",
			   (unsigned int)((100*(diffs[0]+diffs[1])+fill)/dtot),
			   (unsigned int)((100*diffs[2]+fill)/dtot),
			   (unsigned int)((100*diffs[3]+fill)/dtot));
		}

		if ( prev != NULL ) {
		    pmFreeResult (prev);
		}
		s->flip = 1 - s->flip;
		s->res[s->flip] = NULL;

		putchar ('\n');
	    }
	}

	now += (time_t)period;
	
    }
	
    exit(EXIT_SUCCESS);
}
