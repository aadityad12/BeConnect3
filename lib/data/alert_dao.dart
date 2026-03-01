import 'package:sqflite/sqflite.dart';
import 'alert_database.dart';
import 'alert_packet.dart';

class AlertDao {
  /// Inserts or replaces an alert, then prunes to keep at most 20.
  Future<void> insert(AlertPacket alert) async {
    final db = await AlertDatabase.database;
    await db.insert(
      'alerts',
      {
        'alertId':      alert.alertId,
        'severity':     alert.severity,
        'headline':     alert.headline,
        'expires':      alert.expires,
        'instructions': alert.instructions,
        'sourceUrl':    alert.sourceUrl,
        'verified':     alert.verified ? 1 : 0,
        'fetchedAt':    alert.fetchedAt,
        'pinned':       alert.pinned ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await pruneOldAlerts();
  }

  /// Returns true if an alert with this ID is already stored locally.
  /// [alertId] is the 8-char hex string embedded in the BLE manufacturer data.
  Future<bool> hasAlert(String alertId) async {
    final db = await AlertDatabase.database;
    final rows = await db.query(
      'alerts',
      columns: ['alertId'],
      where: 'alertId = ?',
      whereArgs: [alertId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Returns all alerts: pinned first, then by most recently fetched.
  Future<List<AlertPacket>> fetchAll() async {
    final db = await AlertDatabase.database;
    final rows = await db.query(
      'alerts',
      orderBy: 'pinned DESC, fetchedAt DESC',
    );
    return rows
        .map((row) => AlertPacket(
              alertId:      row['alertId'] as String,
              severity:     row['severity'] as String,
              headline:     row['headline'] as String,
              expires:      row['expires'] as int,
              instructions: row['instructions'] as String,
              sourceUrl:    row['sourceUrl'] as String,
              verified:     (row['verified'] as int) == 1,
              fetchedAt:    row['fetchedAt'] as int,
              pinned:       (row['pinned'] as int? ?? 0) == 1,
            ))
        .toList();
  }

  /// Toggles the pinned state of an alert.
  Future<void> setPinned(String alertId, {required bool pinned}) async {
    final db = await AlertDatabase.database;
    await db.update(
      'alerts',
      {'pinned': pinned ? 1 : 0},
      where: 'alertId = ?',
      whereArgs: [alertId],
    );
  }

  /// Deletes a single alert by its unique ID.
  Future<void> deleteAlert(String alertId) async {
    final db = await AlertDatabase.database;
    await db.delete('alerts', where: 'alertId = ?', whereArgs: [alertId]);
  }

  /// Deletes all but the 20 most recently fetched alerts.
  Future<void> pruneOldAlerts() async {
    final db = await AlertDatabase.database;
    await db.execute('''
      DELETE FROM alerts
      WHERE alertId NOT IN (
        SELECT alertId FROM alerts ORDER BY fetchedAt DESC LIMIT 20
      )
    ''');
  }
}
