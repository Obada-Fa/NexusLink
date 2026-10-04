import 'dart:convert';
import 'package:sqflite/sqflite.dart';

/// App-private, host-scoped cache. Drafts are independent of transcript eviction.
class ChatCache {
  final DatabaseFactory? factory;
  final String? databasePath;
  ChatCache({this.factory, this.databasePath});
  Future<Database>? _database;
  Future<Database> get database => _database ??= _open();
  Future<Database> _open() async {
    final path =
        databasePath ?? '${await getDatabasesPath()}/chat-cache.sqlite';
    return (factory ?? databaseFactory).openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE summaries(host TEXT,id TEXT,body TEXT,activity INTEGER,synced INTEGER,PRIMARY KEY(host,id))',
          );
          await db.execute(
            'CREATE TABLE history(host TEXT,id TEXT,body TEXT,bytes INTEGER,access INTEGER,PRIMARY KEY(host,id))',
          );
          await db.execute(
            'CREATE TABLE drafts(host TEXT,id TEXT,text TEXT,position REAL,operation TEXT,PRIMARY KEY(host,id))',
          );
        },
      ),
    );
  }

  Future<List<Map<String, dynamic>>> summaries(String host) async {
    final db = await database;
    final rows = await db.query(
      'summaries',
      where: 'host=?',
      whereArgs: [host],
      orderBy: 'activity DESC,id',
      limit: 500,
    );
    return rows
        .map(
          (row) => Map<String, dynamic>.from(jsonDecode(row['body'] as String)),
        )
        .toList();
  }

  Future<void> saveSummaries(
    String host,
    List<Map<String, dynamic>> rows,
  ) async {
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final row in rows) {
        batch.insert('summaries', {
          'host': host,
          'id': row['id'],
          'body': jsonEncode(row),
          'activity': row['activityAt'],
          'synced': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
      await txn.rawDelete(
        'DELETE FROM summaries WHERE host=? AND id NOT IN (SELECT id FROM summaries WHERE host=? ORDER BY synced DESC,activity DESC LIMIT 500)',
        [host, host],
      );
    });
  }

  Future<Map<String, dynamic>?> history(String host, String id) async {
    final db = await database;
    final rows = await db.query(
      'history',
      where: 'host=? AND id=?',
      whereArgs: [host, id],
    );
    if (rows.isEmpty) return null;
    await db.update(
      'history',
      {'access': DateTime.now().millisecondsSinceEpoch},
      where: 'host=? AND id=?',
      whereArgs: [host, id],
    );
    return Map<String, dynamic>.from(jsonDecode(rows.first['body'] as String));
  }

  Future<void> saveHistory(
    String host,
    String id,
    Map<String, dynamic> page,
  ) async {
    final previous = await history(host, id);
    final events = <String, Map<String, dynamic>>{};
    if (previous?['revision'] == page['revision'] ||
        (previous?['appendOnly'] == true && page['appendOnly'] == true)) {
      for (final event in previous?['events'] as List? ?? []) {
        final row = Map<String, dynamic>.from(event as Map);
        events[row['id'] as String] = row;
      }
    }
    for (final event in page['events'] as List? ?? []) {
      final row = Map<String, dynamic>.from(event as Map);
      events[row['id'] as String] = row;
    }
    final ordered = events.values.toList()
      ..sort((a, b) => (a['seq'] as num).compareTo(b['seq'] as num));
    var saved = {...page, 'events': ordered};
    var body = jsonEncode(saved);
    while (utf8.encode(body).length > 2 * 1024 * 1024 && ordered.isNotEmpty) {
      ordered.removeAt(0);
      saved = {...saved, 'events': ordered, 'completeness': 'partial'};
      body = jsonEncode(saved);
    }
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert('history', {
        'host': host,
        'id': id,
        'body': body,
        'bytes': utf8.encode(body).length,
        'access': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.rawDelete(
        'DELETE FROM history WHERE host=? AND id NOT IN (SELECT id FROM history WHERE host=? ORDER BY access DESC LIMIT 20)',
        [host, host],
      );
      while (true) {
        final total =
            Sqflite.firstIntValue(
              await txn.rawQuery('SELECT COALESCE(SUM(bytes),0) FROM history'),
            ) ??
            0;
        if (total <= 40 * 1024 * 1024) break;
        await txn.rawDelete(
          'DELETE FROM history WHERE rowid=(SELECT rowid FROM history ORDER BY access ASC LIMIT 1)',
        );
      }
    });
  }

  Future<Map<String, Object?>?> draft(String host, String id) async {
    final rows = await (await database).query(
      'drafts',
      where: 'host=? AND id=?',
      whereArgs: [host, id],
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> saveDraft(
    String host,
    String id,
    String text, {
    double? position,
  }) async {
    final db = await database;
    await db.rawInsert(
      'INSERT INTO drafts(host,id,text,position) VALUES (?,?,?,?) ON CONFLICT(host,id) DO UPDATE SET text=excluded.text,position=COALESCE(excluded.position,drafts.position)',
      [host, id, text, position],
    );
  }

  Future<void> saveOperation(String host, String id, String? operation) async {
    final db = await database;
    await db.rawInsert(
      'INSERT INTO drafts(host,id,text,operation) VALUES (?,?,?,?) ON CONFLICT(host,id) DO UPDATE SET operation=excluded.operation',
      [host, id, '', operation],
    );
  }

  Future<int?> lastSync(String host) async => Sqflite.firstIntValue(
    await (await database).rawQuery(
      'SELECT MAX(synced) FROM summaries WHERE host=?',
      [host],
    ),
  );
  Future<void> clear(String host, {bool includeDrafts = false}) async {
    final db = await database;
    await db.transaction((txn) async {
      for (final table in [
        'summaries',
        'history',
        if (includeDrafts) 'drafts',
      ]) {
        await txn.delete(table, where: 'host=?', whereArgs: [host]);
      }
    });
  }
}
