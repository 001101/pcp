/*
 * Copyright (c) 1995 Silicon Graphics, Inc.  All Rights Reserved.
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
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#ifndef CONFIG_H
#define CONFIG_H

typedef struct {
	//double  syscalls;
	double  ctxswitch;
	double  virtualsize;
	double  residentsize;
	double  iodemand;
	double  iowait;
	double  schedwait;
} derived_pred_t;


typedef struct {
        uid_t   uid;         /* real user id */
        gid_t   gid;         /* real group id */
	char	uname[64];
	char	gname[64];
        char    fname[256];     /* basename of exec()'d pathname */
        char    psargs[256];     /* initial chars of arg list */
	double  cpuburn;

        derived_pred_t preds;

} config_vars;

#include "gram_node.h"

void set_conf_buffer( char * );
char *get_conf_buffer();
FILE *open_config(char []);
int read_config(FILE *);
int parse_config(bool_node **tree);
void new_tree(bool_node *tree);
int eval_tree(config_vars *);
void dump_tree(FILE *);
void do_pred_testing(void);
int read_test_values(FILE *, config_vars *);

#endif
