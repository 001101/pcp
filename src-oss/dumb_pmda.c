/*
 * Dumb, a PMDA which never responds to requests ... used in qa/023
 *
 * Copyright (c) 1995-2001 Silicon Graphics, Inc.  All Rights Reserved.
 */

#ident "$Id: dumb_pmda.c,v 1.1 2005/05/10 00:56:48 kenmcd Exp $"

#include <stdio.h>
#include <pcp/pmapi.h>
#include <pcp/impl.h>
#include <pcp/pmda.h>

static void
usage(void)
{
    fprintf(stderr, "Usage: %s [options]\n\n", pmProgname);
    fputs("Options:\n"
	  "  -D N       set pmDebug debugging flag to N\n"
	  "  -d domain  use domain (numeric) for metrics domain of PMDA\n"
	  "  -h helpfile  get help text from helpfile rather then default path\n"
	  "  -l logfile write log into logfile rather than using default log name\n",
	  stderr);
    exit(1);
}

/*
 * Set up the agent if running as a daemon.
 */

int
main(int argc, char **argv)
{
    int			err = 0;
    int			sts;
    pmdaInterface	desc;
    char		*p;
    char		c;

    /* trim cmd name of leading directory components */
    pmProgname = argv[0];
    for (p = pmProgname; *p; p++) {
	if (*p == '/')
	    pmProgname = p+1;
    }

    pmdaDaemon(&desc, PMDA_INTERFACE_3, pmProgname, desc.domain, "dumb_pmda.log", NULL);
    if (desc.status != 0) {
	fprintf(stderr, "pmdaDaemon() failed!\n");
	exit(1);
    }

    if (pmdaGetOpt(argc, argv, "D:d:h:l:", &desc, &err) != EOF)
    	err++;
    if (err)
    	usage();

    pmdaOpenLog(&desc);
    pmdaConnect(&desc);

    /*
     * We have connection to pmcd ... consume PDUs from pmcd,
     * ignore them, and exit on end of file
     */

    while ((sts = read(desc.version.two.ext->e_infd, &c, 1)) == 1)
	;

    if (sts < 0) {
	fprintf(stderr, "dumb_pmda: Error on read from pmcd?: %s\n", strerror(errno));
	exit(1);
	/*NOTREACHED*/
    }

    exit(0);
    /*NOTREACHED*/
}
