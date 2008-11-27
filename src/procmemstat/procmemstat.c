/*
 * procmemstat - sample, simple PMAPI client to report your own memory
 * usage
 *
 * Copyright (c) 2002 Silicon Graphics, Inc.  All Rights Reserved.
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
 */

#include <stdio.h>
#include <unistd.h>
#include <string.h>
#include <sys/types.h>
#include <time.h>
#include "pmapi.h"
#include "impl.h"
#include "pmnsmap.h"

static void
get_sample(void)
{
    int			first = 1;
    static pmResult	*rp;
    static int		numpmid;
    static pmID		*pmidlist;
    static pmDesc	*desclist;
    pmUnits		kbyte_scale;
    int			pid;
    pmAtomValue		tmp;
    pmAtomValue		atom;
    int			sts;
    int			i;

    if (first) {
	memset(&kbyte_scale, 0, sizeof(kbyte_scale));
	kbyte_scale.dimSpace = 1;
	kbyte_scale.scaleSpace = PM_SPACE_KBYTE;

	numpmid = sizeof(metrics) / sizeof(char *);
	if ((pmidlist = (pmID *)malloc(numpmid * sizeof(pmidlist[0]))) == NULL) {
	    fprintf(stderr, "%s: get_sample: malloc: %s\n", pmProgname, strerror(errno));
	    exit(1);
	}
	if ((desclist = (pmDesc *)malloc(numpmid * sizeof(desclist[0]))) == NULL) {
	    fprintf(stderr, "%s: get_sample: malloc: %s\n", pmProgname, strerror(errno));
	    exit(1);
	}
	if ((sts = pmLookupName(numpmid, metrics, pmidlist)) < 0) {
	    printf("%s: pmLookupName: %s\n", pmProgname, pmErrStr(sts));
	    for (i = 0; i < numpmid; i++) {
		if (pmidlist[i] == PM_ID_NULL)
		    fprintf(stderr, "%s: metric \"%s\" not in name space\n", pmProgname, metrics[i]);
	    }
	    exit(1);
	}
	for (i = 0; i < numpmid; i++) {
	    if ((sts = pmLookupDesc(pmidlist[i], &desclist[i])) < 0) {
		fprintf(stderr, "%s: cannot retrieve description for metric \"%s\" (PMID: %s)\nReason: %s\n",
		    pmProgname, metrics[i], pmIDStr(pmidlist[i]), pmErrStr(sts));
		exit(1);
	    }
	}
	/*
	 * All metrics we care about share the same instance domain,
	 * and the instance of interest is _my_ PID
	 */
	pmDelProfile(desclist[0].indom, 0, NULL);	/* all off */
	pid = (int)getpid();
	pmAddProfile(desclist[0].indom, 1, &pid);

	first = 0;
    }

    /* fetch the current metrics */
    if ((sts = pmFetch(numpmid, pmidlist, &rp)) < 0) {
	fprintf(stderr, "%s: pmFetch: %s\n", pmProgname, pmErrStr(sts));
	exit(1);
    }

    printf("memory metrics for pid %d (sizes in Kbytes)\n", (int)pid);
    for (i = 0; i < numpmid; i++) {
	/* process metrics in turn */
	pmExtractValue(rp->vset[i]->valfmt, rp->vset[i]->vlist,
		       desclist[i].type, &tmp, PM_TYPE_U32);
	pmConvScale(PM_TYPE_U32, &tmp, &desclist[i].units,
		    &atom, &kbyte_scale);
	printf("%8d %s\n", atom.l, metrics[i]);
    }
}

int
main(int argc, char **argv)
{
    int			c;
    int			sts;
    char		*p;
    char		*q;
    int			errflag = 0;
    char		host[MAXHOSTNAMELEN];

    __pmSetProgname(argv[0]);
    setlinebuf(stdout);

    while ((c = getopt(argc, argv, "D:?")) != EOF) {
	switch (c) {

	case 'D':	/* debug flag */
	    sts = __pmParseDebug(optarg);
	    if (sts < 0) {
		fprintf(stderr, "%s: unrecognized debug flag specification (%s)\n", pmProgname, optarg);
		errflag++;
	    }
	    else
		pmDebug |= sts;
	    break;

	case '?':
	default:
	    errflag++;
	    break;
	}
    }

    if (errflag || optind < argc-1) {
	fprintf(stderr, "Usage: %s\n", pmProgname);
	exit(1);
    }

    (void)gethostname(host, MAXHOSTNAMELEN);
    host[MAXHOSTNAMELEN-1] = '\0';
    if ((sts = pmNewContext(PM_CONTEXT_HOST, host)) < 0) {
	fprintf(stderr, "%s: Cannot connect to PMCD on host \"%s\": %s\n",
		pmProgname, host, pmErrStr(sts));
	exit(1);
    }

    get_sample();

#define ARRAY 1*1024*1024
    p = (char *)malloc(ARRAY);
    for (q = p; q < &p[ARRAY]; q += 1024)
	*q = '\0';
    printf("\nAfter malloc ...\n");
    get_sample();

    exit(0);
}
