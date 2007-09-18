/*
 * Copyright (c) 1998,2005 Silicon Graphics, Inc.  All Rights Reserved.
 * Copyright (c) 2007 Aconex.  All Rights Reserved.
 * 
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; either version 2.1 of the License, or
 * (at your option) any later version.
 */
#ifndef QMC_SOURCE_H
#define QMC_SOURCE_H

#include <qmc.h>

#include <qlist.h>
#include <qstring.h>
#include <qtextstream.h>

class QmcSource
{
public:
    QmcSource(int type, QString &source);
    ~QmcSource();

    // Get the source description by searching the list of existing sources
    // and returning a new source only if required.
    // If matchHosts is true, then it will attempt to map a live context
    // to an archive source. If no matching archive context is found,
    // a NULL pointer is returned.
    static QmcSource* getSource(int type, QString &source, 
				 bool matchHosts = false);

    // retry context/connection (e.g. if it failed in the constructor)
    void retryConnect(int type, QString &source);

    int status() const { return my.status; }
    int type() const { return my.type; }
    bool isArchive() const { return my.type == PM_CONTEXT_ARCHIVE; }
    QString source() const { return my.source; }
    const char *sourceAscii() const { return (const char*)my.source.toAscii(); }
    QString host() const { return my.host; }
    const char *hostAscii() const { return (const char *)my.host.toAscii(); }
    int tzHandle() const { return my.tz; }
    QString timezone() const { return my.timezone; }
    struct timeval start() const { return my.start; }
    struct timeval end() const { return my.end; }
    QString desc() const { return my.desc; }
    const char *descAscii() const { return (const char *)my.desc.toAscii(); }

    // Number of active contexts to this source
    uint numContexts() const { return my.handles.size(); }

    // Create a new context to this source
    int dupContext();

    // Delete context to this source
    int delContext(int handle);

    // Output the source
    friend QTextStream &operator<<(QTextStream &os, const QmcSource &rhs);

    // Dump all info about a source
    void dump(QTextStream &os);

    // Dump list of known sources
    static void dumpList(QTextStream &os);

private:
    struct {
	int status;
	int type;
	QString source;
	QString host;
	QString	desc;
	QString timezone;
	int tz;
	QList<int> handles;	// Contexts created for this source
	struct timeval start;
	struct timeval end;
	bool dupFlag;		// Dup has been called and 1st context is in use
    } my;

    static QList<QmcSource*> sourceList;
    static QString localHost;
};

#endif	// QMC_SOURCE_H
