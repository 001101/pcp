/*
 * Copyright (c) 1997-2001 Silicon Graphics, Inc.  All Rights Reserved.
 */

#ident "$Id: descreqX2.c,v 1.1 2002/10/25 01:33:55 kenmcd Exp $"

/*
 * 2 DESC_REQs back-to-back ... trying to understand www.sgi.com PMDA deaths
 */

#include <stdio.h>
#include <pcp/pmapi.h>
#include <pcp/impl.h>

int
main(argc, argv)
int argc;
char *argv[];
{
    int		c;
    int		fd;
    int		ctx;
    char	*p;
    int		errflag = 0;
    int		e;
    int		sts;
    __pmContext	*ctxp;
    __pmPDU	*pb;
    pmID	pmid;
    char	*name = "sample.seconds";
    extern char	*optarg;
    extern int	optind;
    extern int	pmDebug;

    /* trim command name of leading directory components */
    pmProgname = argv[0];
    for (p = pmProgname; *p; p++) {
	if (*p == '/')
	    pmProgname = p+1;
    }

    if (argc > 1) {
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

	if (errflag || optind > argc) {
	    fprintf(stderr, "Usage: %s [-D]\n", pmProgname);
	    exit(1);
	}
    }

    if ((ctx = pmNewContext(PM_CONTEXT_HOST, "localhost")) < 0) {
	fprintf(stderr, "pmNewContext: %s\n", pmErrStr(ctx));
	exit(1);
    }

    ctxp = __pmHandleToPtr(ctx);
    fd = ctxp->c_pmcd->pc_fd;

    if ((e = pmLoadNameSpace(PM_NS_DEFAULT)) < 0) {
	fprintf(stderr, "pmLoadNameSpace: %s\n", pmErrStr(e));
	exit(1);
    }

    if ((e = pmLookupName(1, &name, &pmid)) < 0) {
	printf("pmLookupName: Unexpected error: %s\n", pmErrStr(e));
	exit(1);
    }

    if ((e = __pmSendDescReq(fd, PDU_BINARY, pmid)) < 0) {
	fprintf(stderr, "Error: SendDescReqX1: %s\n", pmErrStr(e));
	exit(1);
    }

    if ((e = __pmSendDescReq(fd, PDU_BINARY, pmid)) < 0) {
	fprintf(stderr, "Error: SendDescReqX2: %s\n", pmErrStr(e));
	exit(1);
    }

    if ((e = __pmGetPDU(fd, PDU_BINARY, TIMEOUT_DEFAULT, &pb)) < 0)
	fprintf(stderr, "Error: __pmGetPDUX1: %s\n", pmErrStr(e));
    else
	fprintf(stderr, "__pmGetPDUX1 -> 0x%x\n", e);

    if ((e = __pmGetPDU(fd, PDU_BINARY, TIMEOUT_DEFAULT, &pb)) < 0)
	fprintf(stderr, "Error: __pmGetPDUX2: %s\n", pmErrStr(e));
    else
	fprintf(stderr, "__pmGetPDUX2 -> 0x%x\n", e);

    exit(0);
    /*NOTREACHED*/
}

