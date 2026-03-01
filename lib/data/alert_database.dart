import 'package:path/path.dart' show join;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class AlertDatabase {
  AlertDatabase._();

  static Database? _db;

  static Future<Database> get database async {
    _db ??= await _initDb();
    return _db!;
  }

  static Future<Database> _initDb() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = join(dir.path, 'beconnect.db');
    return openDatabase(
      path,
      version: 3,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE alerts (
            alertId       TEXT    PRIMARY KEY,
            severity      TEXT    NOT NULL,
            headline      TEXT    NOT NULL,
            expires       INTEGER NOT NULL,
            instructions  TEXT    NOT NULL,
            sourceUrl     TEXT    NOT NULL,
            verified      INTEGER NOT NULL,
            fetchedAt     INTEGER NOT NULL,
            pinned        INTEGER NOT NULL DEFAULT 0,
            hopCount      INTEGER NOT NULL DEFAULT 0
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE alerts ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0',
          );
        }
        if (oldVersion < 3) {
          await db.execute(
            'ALTER TABLE alerts ADD COLUMN hopCount INTEGER NOT NULL DEFAULT 0',
          );
        }
      },
    );
  }
}
