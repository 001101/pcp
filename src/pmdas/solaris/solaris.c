/*
 * Solaris PMDA
 *
 * Collect performance data from the Solaris kernel using kstat() for
 * the most part.
 *
 * Copyright (c) 2004 Silicon Graphics, Inc.  All Rights Reserved.
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

#include <time.h>
#include <sys/time.h>
#include "common.h"

static int	_isDSO = 1;
static char	mypath[MAXPATHLEN];

/*
 * wrapper for pmdaFetch which primes the methods ready for
 * the next fetch
 * ... real callback is fetch_callback()
 */
static int
solaris_fetch(int numpmid, pmID pmidlist[], pmResult **resp, pmdaExt *pmda)
{
    int		i;

    for (i = 0; i < methodtab_sz; i++) {
	methodtab[i].m_fetched = 0;
    }

    return pmdaFetch(numpmid, pmidlist, resp, pmda);
}

/*
 * callback provided to pmdaFetch
 */
static int
solaris_fetch_callback(pmdaMetric *mdesc, unsigned int inst, pmAtomValue *atom)
{
    metricdesc_t *mdp = (metricdesc_t *)mdesc->m_user;
    method_t *m = methodtab + mdp->md_method;
    hrtime_t start;
    int rv;
    __pmID_int *id = __pmid_int(&mdesc->m_desc.pmid);

    if (id->cluster == 4095) {
	switch (id->item) {
	case 0:
		if ((inst <= 0) || (inst > methodtab_sz+1))
			return PM_ERR_INST;
		atom->ull = methodtab[inst-1].m_elapsed;
		return 1;
	case 1:
		if ((inst <= 0) || (inst > methodtab_sz+1))
			return PM_ERR_INST;
		atom->ull = methodtab[inst-1].m_hits;
		return 1;
	case 2:
		if ((inst <= 0) || (inst > metrictab_sz+1))
			return PM_ERR_INST;
		atom->ull = metricdesc[inst-1].md_elapsed;
		return 1;
	case 3:
		if ((inst <= 0) || (inst > metrictab_sz+1))
			return PM_ERR_INST;
		atom->ull = metricdesc[inst-1].md_hits;
		return 1;
	default:
		return PM_ERR_PMID;
	}
    }

    if (!m->m_fetched && m->m_prefetch) {
	start = gethrtime();
	m->m_prefetch();
	m->m_elapsed = gethrtime() - start;
	m->m_hits++;
	m->m_fetched = 1;
    }
    start = gethrtime();
    rv = m->m_fetch(mdesc, inst, atom);
    mdp->md_elapsed = gethrtime() - start;
    mdp->md_hits++;
    return rv;
}

/*
 * Initialise the agent (both daemon and DSO).
 */
void 
solaris_init(pmdaInterface *dp)
{
    if (_isDSO) {
	int sep = __pmPathSeparator();
	snprintf(mypath, sizeof(mypath), "%s%c" "solaris" "%c" "help",
		pmGetConfig("PCP_PMDAS_DIR"), sep, sep);
	pmdaDSO(dp, PMDA_INTERFACE_3, "Solaris DSO", mypath);
    }

    if (dp->status != 0)
	return;

    dp->version.two.fetch = solaris_fetch;
    pmdaSetFetchCallBack(dp, solaris_fetch_callback);
    init_data(dp->domain);
    pmdaInit(dp, indomtab, indomtab_sz, metrictab, metrictab_sz);
}

static void
usage(void)
{
    fprintf(stderr, "Usage: %s [options]\n\n", pmProgname);
    fputs("Options:\n"
	  "  -d domain    use domain (numeric) for metrics domain of PMDA\n"
	  "  -l logfile   write log into logfile rather than using default log name\n",
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
    int			sep = __pmPathSeparator();
    pmdaInterface	desc;

    _isDSO = 0;
    __pmSetProgname(argv[0]);

    snprintf(mypath, sizeof(mypath), "%s%c" "solaris" "%c" "help",
		pmGetConfig("PCP_PMDAS_DIR"), sep, sep);
    pmdaDaemon(&desc, PMDA_INTERFACE_3, pmProgname, SOLARIS,
		"solaris.log", mypath);

    if (pmdaGetOpt(argc, argv, "D:d:l:?", &desc, &err) != EOF)
	err++;
    if (err)
	usage();

    pmdaOpenLog(&desc);
    solaris_init(&desc);
    pmdaConnect(&desc);
    pmdaMain(&desc);

    exit(0);
}
