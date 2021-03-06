/* This Source Code Form is subject to the terms of the Mozilla Public
* License, v. 2.0. If a copy of the MPL was not distributed with this
* file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

let HistoryVisits = "history-visits"

// This isn't a real table. Its an abstraction around the history and visits table
// to simpify queries that should join both tables. It also handles making sure that
// inserts/updates/delete update both tables appropriately. i.e.
// 1.) Deleteing a history entry here will also remove all visits to it
// 2.) Adding a visit here will ensure that a site exists for the visit
// 3.) Updates currently only update site information.
class JoinedHistoryVisitsTable: Table {
    typealias Type = (site: Site?, visit: Visit?)
    var name: String { return HistoryVisits }

    private let visits = VisitsTable<Visit>()
    private let history = HistoryTable<Site>()

    private func getIDFor(db: SQLiteDBConnection, site: Site) -> Int? {
        let opts = QueryOptions()
        opts.filter = site.url

        let cursor = history.query(db, options: opts)
        if (cursor.count != 1) {
            return nil
        }
        return (cursor[0] as Site).id
    }

    func create(db: SQLiteDBConnection, version: Int) -> Bool {
        return history.create(db, version: version) && visits.create(db, version: version)
    }

    func updateTable(db: SQLiteDBConnection, from: Int, to: Int) -> Bool {
        return history.updateTable(db, from: from, to: to) && visits.updateTable(db, from: from, to: to)
    }

    private func updateSite(db: SQLiteDBConnection, site: Site, inout err: NSError?) -> Int {
        // If our site doesn't have an id, we need to find one
        if site.id == nil {
            if let id = getIDFor(db, site: site) {
                site.id = id
                // Update the page title
                return history.update(db, item: site, err: &err)
            } else {
                // Make sure we have a site in the table first
                site.id = history.insert(db, item: site, err: &err)
                return 1
            }
        }

        // Update the page title
        return history.update(db, item: site, err: &err)
    }

    func insert(db: SQLiteDBConnection, item: Type?, inout err: NSError?) -> Int {
        if let visit = item?.visit {
            if updateSite(db, site: visit.site, err: &err) < 0 {
                return -1;
            }

            // Now add a visit
            return visits.insert(db, item: visit, err: &err)
        } else if let site = item?.site {
            if updateSite(db, site: site, err: &err) < 0 {
                return -1;
            }

            // Now add a visit
            let visit = Visit(site: site, date: NSDate())
            return visits.insert(db, item: visit, err: &err)
        }

        return -1
    }

    func update(db: SQLiteDBConnection, item: Type?, inout err: NSError?) -> Int {
        return visits.update(db, item: item?.visit, err: &err);
    }

    func delete(db: SQLiteDBConnection, item: Type?, inout err: NSError?) -> Int {
        if let visit = item?.visit {
            return visits.delete(db, item: visit, err: &err)
        } else if let site = item?.site {
            let v = Visit(site: site, date: NSDate())
            visits.delete(db, item: v, err: &err)
            return history.delete(db, item: site, err: &err)
        } else if item == nil {
            let site: Site? = nil
            let visit: Visit? = nil
            history.delete(db, item: site, err: &err);
            return visits.delete(db, item: visit, err: &err);
        }
        return -1
    }

    func factory(result: SDRow) -> (site: Site, visit: Visit) {
        let site = Site(url: result["url"] as String, title: result["title"] as String)
        site.guid = result["guid"] as? String
        site.id = result["siteId"] as? Int

        let d = NSDate(timeIntervalSince1970: result["date"] as Double)
        let type = VisitType(rawValue: result["type"] as Int)
        let visit = Visit(site: site, date: d, type: type!)
        visit.id = result["visitId"] as Int
        return (site, visit)
    }

    func query(db: SQLiteDBConnection, options: QueryOptions?) -> Cursor {
        var args = [AnyObject?]()
        var sql = "SELECT \(history.name).id as siteId, \(visits.name).id as visitId, url, title, guid, date, type FROM \(visits.name) " +
            "INNER JOIN \(history.name) ON \(history.name).id = \(visits.name).siteId ";

        if let filter = options?.filter {
            sql += "WHERE url LIKE ? "
            args.append("%\(filter)%")
        }

        sql += "GROUP BY siteId";

        // Trying to do this in one line (i.e. options?.sort == .LastVisit) breaks the Swift compiler
        if let sort = options?.sort {
            if sort == .LastVisit {
                sql += " ORDER BY date DESC"
            }
        }

        return db.executeQuery(sql, factory: factory, withArgs: args)
    }
}
