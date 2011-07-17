/*
 * Copyright (c) 2011 Ken McDonell.  All Rights Reserved.
 *
 * exercise multi-threaded multiple host contexts with pmLookupDesc()
 * as the simplest possible case
 */

#include <stdio.h>
#include <stdlib.h>
#include <pcp/pmapi.h>
#include <pcp/impl.h>
#include <pthread.h>

#define NMETRIC 5

static char	*namelist[NMETRIC] = {
    "sample.seconds",
    "sampledso.milliseconds",
    "sample.ulonglong.bin_ctr",
    "disk.dev.total",
    "hinv.ncpu"
};
static pmID	pmidlist[NMETRIC];

static pthread_barrier_t barrier;

static int ctx1;
static int ctx2;

static void
foo(FILE *f, char *fn, int i)
{
    pmDesc	desc;
    char	strbuf[60];
    int		sts;

    sts = pmLookupDesc(pmidlist[i], &desc);
    if (sts < 0) {
	fprintf(f, "%s: pmLookupDesc[%s] -> %s\n", fn, pmIDStr_r(pmidlist[i], strbuf, sizeof(strbuf)), pmErrStr(sts));
	pthread_exit("botch");
    }
    else if (pmidlist[i] != desc.pmid) {
	fprintf(f, "%s: pmLookupDesc: Expecting PMID: %s", fn, pmIDStr_r(pmidlist[i], strbuf, sizeof(strbuf)));
	fprintf(f, " got: %s\n", pmIDStr_r(desc.pmid, strbuf, sizeof(strbuf)));
	pthread_exit("botch");
    }
    else {
	fprintf(f, "%s: %s (%s) ->", fn, namelist[i], pmIDStr_r(pmidlist[i], strbuf, sizeof(strbuf)));
	fprintf(f, " %s", pmTypeStr_r(desc.type, strbuf, sizeof(strbuf)));
	fprintf(f, " %s", pmInDomStr_r(desc.indom, strbuf, sizeof(strbuf)));
	if (desc.sem == PM_SEM_COUNTER) fprintf(f, " counter");
	else if (desc.sem == PM_SEM_INSTANT) fprintf(f, " instant");
	else if (desc.sem == PM_SEM_DISCRETE) fprintf(f, " discrete");
	else fprintf(f, " sem-%d", desc.sem);
	fprintf(f, " %s\n", pmUnitsStr_r(&desc.units, strbuf, sizeof(strbuf)));
    }
}

static void *
func1(void *arg)
{
    char	*fn = "func1";
    int		i;
    int		j;
    FILE	*f;

    f = fopen("/tmp/func1.out", "w");

    j = pmUseContext(ctx1);
    if ( j < 0) {
	fprintf(f, "Error: %s: pmUseContext(%d) -> %s\n", fn, ctx1, pmErrStr(j));
	pthread_exit("botch");
    }

    pthread_barrier_wait(&barrier);

    for (j = 0; j < 100; j++) {
	for (i = 0; i < NMETRIC; i++) {
	    foo(f, fn, i);
	}
    }

    pthread_exit(NULL);
}

static void *
func2(void *arg)
{
    char	*fn = "func2";
    int		i;
    int		j;
    FILE	*f;

    f = fopen("/tmp/func2.out", "w");

    j = pmUseContext(ctx2);
    if ( j < 0) {
	fprintf(f, "Error: %s: pmUseContext(%d) -> %s\n", fn, ctx2, pmErrStr(j));
	pthread_exit("botch");
    }

    pthread_barrier_wait(&barrier);

    for (j = 0; j < 100; j++) {
	for (i = NMETRIC-1; i >= 0; i--) {
	    foo(f, fn, i);
	}
    }

    pthread_exit(NULL);
}

int
main(int argc, char **argv)
{
    pthread_t	tid1;
    pthread_t	tid2;
    int		sts;
    char	*msg;
    int		errflag = 0;
    int		c;

    __pmSetProgname(argv[0]);

    while ((c = getopt(argc, argv, "D:")) != EOF) {
	switch (c) {

#ifdef PCP_DEBUG
	case 'D':	/* debug flag */
	    sts = __pmParseDebug(optarg);
	    if (sts < 0) {
		fprintf(stderr, "%s: unrecognized debug flag specification (%s)\n",
		    pmProgname, optarg);
		errflag++;
	    }
	    else
		pmDebug |= sts;
	    break;
#endif

	case '?':
	default:
	    errflag++;
	    break;
	}
    }

    if (errflag || optind == argc || argc-optind > 2) {
	fprintf(stderr, "Usage: %s [-D...] host1 [host2]\n", pmProgname);
	exit(1);
    }

    ctx1 = pmNewContext(PM_CONTEXT_HOST, argv[optind]);
    if (ctx1 < 0) {
	printf("Error: pmNewContext(%s) -> %s\n", argv[optind], pmErrStr(ctx1));
	exit(1);
    }
    optind++;

    if (optind < argc) {
	ctx2 = pmNewContext(PM_CONTEXT_HOST, argv[optind]);
	if (ctx2 < 0) {
	    printf("Error: pmNewContext(%s) -> %s\n", argv[optind], pmErrStr(ctx2));
	    exit(1);
	}
    }
    else
	ctx2 = ctx1;

    sts = pmLookupName(NMETRIC, namelist, pmidlist);
    if (sts != NMETRIC) {
	int	i;
	printf("Error: pmLookupName -> %s\n", pmErrStr(sts));
	for (i = 0; i < NMETRIC; i++) {
	    printf("    %s -> %s\n", namelist[i], pmIDStr(pmidlist[i]));
	}
	exit(1);
    }

    sts = pthread_barrier_init(&barrier, NULL, 2);
    if (sts != 0) {
	printf("pthread_barrier_init: sts=%d\n", sts);
	exit(1);
    }

    sts = pthread_create(&tid1, NULL, func1, NULL);
    if (sts != 0) {
	printf("thread_create: tid1: sts=%d\n", sts);
	exit(1);
    }
    sts = pthread_create(&tid2, NULL, func2, NULL);
    if (sts != 0) {
	printf("thread_create: tid2: sts=%d\n", sts);
	exit(1);
    }

    pthread_join(tid1, (void *)&msg);
    if (msg != NULL) printf("tid1: %s\n", msg);
    pthread_join(tid2, (void *)&msg); 
    if (msg != NULL) printf("tid2: %s\n", msg);

    exit(0);
}
