/*
 * Copyright (c) 1995-2003 Silicon Graphics, Inc.  All Rights Reserved.
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
#include <sys/stat.h>
#include <sys/file.h>

static int
mkdir_r(char *path)
{
    struct stat	sbuf;

    if (stat(path, &sbuf) < 0) {
	if (mkdir_r(dirname(strdup(path))) < 0)
	    return -1;
	return mkdir2(path, 0755);
    }
    else if ((sbuf.st_mode & S_IFDIR) == 0) {
	fprintf(stderr, "pmpost: \"%s\" is not a directory\n", path);
	exit(1);
    }
    return 0;
}

#define LAST_UNDEFINED	-1
#define LAST_NEWFILE	-2

int
main(int argc, char **argv)
{
    int		i;
    int		fd;
    FILE	*np;
    char	*dir;
    struct stat	sbuf;
    time_t	now;
    int		lastday = LAST_UNDEFINED;
    struct tm	*tmp;
    int		sts = 0;
    char	notices[MAXPATHLEN];
    char	*tz = getenv("TZ");
    struct flock lock;
    extern char **environ;
    static char *newenviron[] =
	{"HOME=/nowhere", "SHELL=/noshell", "PATH=/nowhere", NULL};

    /*
     * Fix for bug #827972, do not trust the environment.
     * See also below.
     */
    environ = newenviron;
    if (tz && strlen(tz) < sizeof(notices)-4) {
    	snprintf(notices, sizeof(notices), "TZ=%s", tz);
	if ((tz = strdup(notices)) != NULL)
	    putenv(tz);
    }
    umask(0022);

    if ((argc == 1) || (argc == 2 && strcmp(argv[1], "-?") == 0)) {
	fprintf(stderr, "Usage: pmpost message\n");
	exit(1);
    }

    snprintf(notices, sizeof(notices), "%s/NOTICES", pmGetConfig("PCP_LOG_DIR"));

    dir = dirname(strdup(notices));
    if (mkdir_r(dir) < 0) {
	fprintf(stderr, "pmpost: cannot create directory \"%s\": %s\n",
	    dir, strerror(errno));
	exit(1);
    }


    if ((fd = open(notices, O_WRONLY, 0)) < 0) {
	if ((fd = open(notices, O_WRONLY|O_CREAT, 0644)) < 0) {
	    fprintf(stderr, "pmpost: cannot create file \"%s\": %s\n",
		notices, strerror(errno));
	    exit(1);
	}
	lastday = LAST_NEWFILE;
    }

    /*
     * drop root privileges for bug #827972
     */
    if (setuid(getuid()) < 0)
    	exit(1);

    lock.l_type = F_WRLCK;
    lock.l_whence = 0;
    lock.l_start = 0;
    lock.l_len = 0;

    /*
     * willing to try for 3 seconds to get the lock ... note fcntl()
     * does not block, unlike flock()
     */
    for (i = 0; i < 3; i++) {
	if ((sts = fcntl(fd, F_SETLK, &lock)) != -1)
	    break;
	sleep(1);
    }
    
    if (sts == -1) {
	fprintf(stderr, "pmpost: warning, cannot lock file \"%s\"", notices);
	if (errno != EINTR)
	    fprintf(stderr, ": %s", strerror(errno));
	fputc('\n', stderr);
    }
    sts = 0;

    /*
     * have lock, get last modified day unless file just created
     */
    if (lastday != LAST_NEWFILE) {
	if (fstat(fd, &sbuf) < 0)
	    /* should never happen */
	    ;
	else {
	    tmp = localtime(&sbuf.st_mtime);
	    lastday = tmp->tm_yday;
	}
    }

    if ((np = fdopen(fd, "a")) == NULL) {
	fprintf(stderr, "pmpost: fdopen: %s\n", strerror(errno));
	exit(1);
    }

    time(&now);
    tmp = localtime(&now);

    if (lastday != tmp->tm_yday) {
	if (fprintf(np, "\nDATE: %s", ctime(&now)) < 0)
	    sts = errno;
    }

    if (fprintf(np, "%02d:%02d", tmp->tm_hour, tmp->tm_min) < 0)
	sts = errno;

    for (i = 1; i < argc; i++) {
	if (fprintf(np, " %s", argv[i]) < 0)
	    sts = errno;
    }

    if (fputc('\n', np) < 0)
	sts = errno;

    if (fclose(np) < 0)
	sts = errno;

    if (sts < 0) {
	fprintf(stderr, "pmpost: write failed: %s\n", strerror(errno));
	fprintf(stderr, "Lost message ...");
	for (i = 1; i < argc; i++) {
	    fprintf(stderr, " %s", argv[i]);
	}
	fputc('\n', stderr);
    }

    exit(0);
}
