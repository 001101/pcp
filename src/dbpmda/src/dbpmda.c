/*
 * Copyright (c) 1995-2002 Silicon Graphics, Inc.  All Rights Reserved.
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

#include "dbpmda.h"
#include "lex.h"
#include "gram.h"
#include <ctype.h>

char		*configfile = NULL;
__pmLogCtl	logctl;
int		parse_done = 0;
int		primary = 0;		/* Non-zero for primary pmlc */
pid_t		pid = (pid_t) -1;
int		zflag = 0;		/* for -z */
char		*pmnsfile = PM_NS_DEFAULT;
char		*cmd_namespace = NULL; /* namespace given from command */
int             _creds_timeout = 3;     /* Timeout for agents credential PDU */

int		connmode = PDU_NOT;
int		stmt_type;
int		eflag;
int		iflag;

extern int yyparse(void);

int
main(int argc, char **argv)
{
    int			c;
    int			sts;
    int			errflag = 0;
    char		*endnum;
    int			i;

    __pmSetProgname(argv[0]);

#ifdef HAVE_GETOPT_NEEDS_POSIXLY_CORRECT
    /*
     * dbpmda mimics pmcd wrt POSIX getopt(2) handling, which is:
     * "pmcd does not really need this for its own options because the
     * arguments like "arg -x" are not valid.  But the PMDA's launched
     * by pmcd from pmcd.conf may not be so lucky."
     */
    putenv("POSIXLY_CORRECT=");
#endif

    iflag = isatty(0);

    while ((c = getopt(argc, argv, "q:D:ein:?")) != EOF) {
	switch (c) {

#ifdef PCP_DEBUG
	case 'D':		/* debug flag */
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

	case 'e':		/* echo input */
	    eflag++;
	    break;

	case 'i':		/* be interactive */
	    iflag = 1;
	    break;

	case 'n':		/* alternative name space file */
	    pmnsfile = optarg;
	    break;

	case 'q':
            {
	        int val = (int)strtol(optarg, &endnum, 10);
		if (*endnum != '\0' || val <= 0.0) {
		    fprintf(stderr,
			    "pmcd: -q requires a postive numeric argument\n");
		    errflag++;
		}
		else
		    _creds_timeout = val;
	    }
	    break;


	case '?':
	default:
	    errflag++;
	    break;
	}
    }

    if ((i = argc - optind) > 0) {
	if (i > 1)
	    errflag++;
	else {
	    /* pid was specified */
	    if (primary) {
		fprintf(stderr, "%s: you may not specify both -P and a pid\n", pmProgname);
		errflag++;
	    }
	    else {
		pid = (int)strtol(argv[optind], &endnum, 10);
		if (*endnum != '\0') {
		    fprintf(stderr, "%s: pid must be a numeric process id\n", pmProgname);
		    errflag++;
		}
	    }
	}
    }

    if (errflag) {
	fprintf(stderr,
		"Usage: %s [options]\n\n"
		"Options:\n"
		"  -e            echo input\n"
		"  -i            be interactive and prompt\n"
		"  -n pmnsfile   use an alternative PMNS\n"
		"  -q timeout    PMDA initial negotiation timeout (seconds) "
                                "[default 3]\n",
		pmProgname);
	exit(1);
    }

    if ((sts = pmLoadNameSpace(pmnsfile)) < 0) {
	fprintf(stderr, "%s: Cannot load namespace from \"%s\": %s\n",
		pmProgname, pmnsfile, pmErrStr(sts));
	exit(1);
    }

    /* initialize the "fake context" ... */
    pmWhichContext();

    setlinebuf(stdout);
    setlinebuf(stderr);

    for ( ; ; ) {
	initmetriclist();
	yyparse();
	if (yywrap()) {
	    if (iflag)
		putchar('\n');
	    break;
	}

	__pmSetInternalState(PM_STATE_PMCS);

	switch (stmt_type) {

	    case OPEN:
		profile_changed = 1;
		break;

	    case CLOSE:
		switch (connmode) {
		    case PDU_DSO:
			closedso();
			break;
		    
		    case PDU_BINARY:
			closepmda();
			break;
		    
		    case PDU_NOT:
			yywarn("No PMDA currently opened");
			break;
		}
		connmode = PDU_NOT;
		break;

	    case DESC:
		switch (connmode) {
		    case PDU_DSO:
			dodso(PDU_DESC_REQ);
			break;
		    
		    case PDU_BINARY:
			dopmda(PDU_DESC_REQ);
			break;
		    
		    case PDU_NOT:
			yywarn("No PMDA currently opened");
			break;
		}
		break;

	    case FETCH:
		switch (connmode) {
		    case PDU_DSO:
			dodso(PDU_FETCH);
			break;
		    
		    case PDU_BINARY:
			dopmda(PDU_FETCH);
			break;
		    
		    case PDU_NOT:
			yywarn("No PMDA currently opened");
			break;
		}
		break;

	    case INSTANCE:
		switch (connmode) {
		    case PDU_DSO:
			dodso(PDU_INSTANCE_REQ);
			break;
		    
		    case PDU_BINARY:
			dopmda(PDU_INSTANCE_REQ);
			break;
		    
		    case PDU_NOT:
			yywarn("No PMDA currently opened");
			break;
		}
		break;

	    case STORE:
		switch (connmode) {
		    case PDU_DSO:
			dodso(PDU_RESULT);
			break;
		    
		    case PDU_BINARY:
			dopmda(PDU_RESULT);
			break;
		    
		    case PDU_NOT:
			yywarn("No PMDA currently opened");
			break;
		}
		break;

	    case HELP:
		dohelp(param.number, param.pmid);
		break;

	    case WATCH:
		break;

	    case DBG:
		pmDebug = param.number;
		break;

	    case QUIT:
		exit(0);

	    case STATUS:
		dostatus();
		break;

	    case INFO:
		switch (connmode) {
		case PDU_DSO:
		    dodso(PDU_TEXT_REQ);
		    break;

		case PDU_BINARY:
		    dopmda(PDU_TEXT_REQ);
		    break;

		case PDU_NOT:
		    yywarn("No PMDA currently opened");
		    break;
		}
		break;
	    case NAMESPACE:
		if (cmd_namespace != NULL)
		    free(cmd_namespace);
		cmd_namespace = strdup(param.name);
		if (cmd_namespace == NULL) {
		    fprintf(stderr, "%s: No memory for new namespace\n",
			    pmProgname);
		    exit(1);
		}
		pmUnloadNameSpace();
		strcpy(cmd_namespace, param.name);
		if ((sts = pmLoadNameSpace(cmd_namespace)) < 0) {
		    fprintf(stderr, "%s: Cannot load namespace from \"%s\": %s\n",
			    pmProgname, cmd_namespace, pmErrStr(sts));
                    fprintf(stderr, "%s: Reload default namespace \"%s\"\n",
			    pmProgname, pmnsfile);
		    if ((sts = pmLoadNameSpace(pmnsfile)) < 0) {
			fprintf(stderr, "%s: Cannot load namespace from \"%s\": %s\n",
				pmProgname, pmnsfile, pmErrStr(sts));
			exit(1);
		    }
		}
		break;

	    case EOL:
		break;

	    case PMNS_NAME:
		switch (connmode) {
		    case PDU_DSO:
			dodso(PDU_PMNS_IDS);
			break;
		    
		    case PDU_BINARY:
			dopmda(PDU_PMNS_IDS);
			break;
		    
		    case PDU_NOT:
			yywarn("No PMDA currently opened");
			break;
		}
		break;

	    case PMNS_PMID:
		switch (connmode) {
		    case PDU_DSO:
			dodso(PDU_PMNS_NAMES);
			break;
		    
		    case PDU_BINARY:
			dopmda(PDU_PMNS_NAMES);
			break;
		    
		    case PDU_NOT:
			yywarn("No PMDA currently opened");
			break;
		}
		break;

	    case PMNS_CHILDREN:
		switch (connmode) {
		    case PDU_DSO:
			dodso(PDU_PMNS_CHILD);
			break;
		    
		    case PDU_BINARY:
			dopmda(PDU_PMNS_CHILD);
			break;
		    
		    case PDU_NOT:
			yywarn("No PMDA currently opened");
			break;
		}
		break;

	    case PMNS_TRAVERSE:
		switch (connmode) {
		    case PDU_DSO:
			dodso(PDU_PMNS_TRAVERSE);
			break;
		    
		    case PDU_BINARY:
			dopmda(PDU_PMNS_TRAVERSE);
			break;
		    
		    case PDU_NOT:
			yywarn("No PMDA currently opened");
			break;
		}
		break;

	    default:
		printf("Unexpected result (%d) from parser?\n", stmt_type);
		break;
	}
	__pmSetInternalState(PM_STATE_APPL);
    }

    exit(0);
}
