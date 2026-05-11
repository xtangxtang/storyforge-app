import 'dart:convert';
import '../database.dart';
import '../../models/models.dart';
import 'package:sqflite/sqflite.dart';

class ProjectDao {
  final AppDatabase _db = AppDatabase();

  Future<List<Project>> getAll() async {
    final db = await _db.database;
    final maps = await db.query('projects', orderBy: 'created_at DESC');
    return maps.map((m) => Project.fromMap(m)).toList();
  }

  Future<Project?> getById(String id) async {
    final db = await _db.database;
    final maps = await db.query('projects', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return Project.fromMap(maps.first);
  }

  Future<void> insert(Project project) async {
    final db = await _db.database;
    await db.insert('projects', project.toMap());
  }

  Future<void> updateState(String id, String state) async {
    final db = await _db.database;
    await db.update(
      'projects',
      {'state': state, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> updateBudget(String id, double used) async {
    final db = await _db.database;
    await db.update(
      'projects',
      {
        'budget_used': used,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> delete(String id) async {
    final db = await _db.database;
    await db.transaction((txn) async {
      for (final table in [
        'tasks',
        'video_clips',
        'final_cuts',
        'storyboards',
        'assets',
        'scripts',
        'briefs',
      ]) {
        await txn.delete(table, where: 'project_id = ?', whereArgs: [id]);
      }
      await txn.delete('projects', where: 'id = ?', whereArgs: [id]);
    });
  }
}

class BriefDao {
  final AppDatabase _db = AppDatabase();

  Future<Brief?> getByProjectId(String projectId) async {
    final db = await _db.database;
    final maps = await db.query(
      'briefs',
      where: 'project_id = ?',
      whereArgs: [projectId],
    );
    if (maps.isEmpty) return null;
    return Brief.fromMap(maps.first);
  }

  Future<void> insert(Brief brief) async {
    final db = await _db.database;
    await db.insert('briefs', brief.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
}

class ScriptDao {
  final AppDatabase _db = AppDatabase();

  Future<Script?> getByProjectId(String projectId) async {
    final db = await _db.database;
    final maps = await db.query(
      'scripts',
      where: 'project_id = ?',
      whereArgs: [projectId],
    );
    if (maps.isEmpty) return null;
    return Script.fromMap(maps.first);
  }

  Future<void> insert(Script script) async {
    final db = await _db.database;
    await db.insert('scripts', script.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
}

class AssetDao {
  final AppDatabase _db = AppDatabase();

  Future<List<Asset>> getByProjectId(String projectId) async {
    final db = await _db.database;
    final maps = await db.query(
      'assets',
      where: 'project_id = ?',
      whereArgs: [projectId],
      orderBy: 'created_at',
    );
    return maps.map((m) => Asset.fromMap(m)).toList();
  }

  Future<void> insert(Asset asset) async {
    final db = await _db.database;
    await db.insert('assets', asset.toMap());
  }

  Future<void> insertAll(List<Asset> assets) async {
    final db = await _db.database;
    for (final asset in assets) {
      await db.insert('assets', asset.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  Future<void> updateReferenceImage(
    String assetId, {
    String? imageUrl,
    String? localPath,
  }) async {
    final db = await _db.database;
    final updates = <String, dynamic>{};
    if (imageUrl != null) updates['reference_image_url'] = imageUrl;
    if (localPath != null) updates['reference_image_local_path'] = localPath;
    if (updates.isEmpty) return;
    await db.update(
      'assets',
      updates,
      where: 'id = ?',
      whereArgs: [assetId],
    );
  }

  Future<void> updateReferenceImageUrl(String assetId, String imageUrl) async {
    await updateReferenceImage(assetId, imageUrl: imageUrl);
  }
}

class StoryboardDao {
  final AppDatabase _db = AppDatabase();

  Future<List<Storyboard>> getByProjectId(String projectId) async {
    final db = await _db.database;
    final maps = await db.query(
      'storyboards',
      where: 'project_id = ?',
      whereArgs: [projectId],
      orderBy: 'scene_num, shot_num',
    );
    return maps.map((m) => Storyboard.fromMap(m)).toList();
  }

  Future<void> insert(Storyboard sb) async {
    final db = await _db.database;
    await db.insert('storyboards', sb.toMap());
  }

  Future<void> insertAll(List<Storyboard> sbs) async {
    final db = await _db.database;
    for (final sb in sbs) {
      await db.insert('storyboards', sb.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  Future<void> updateState(String id, String state) async {
    final db = await _db.database;
    await db.update(
      'storyboards',
      {'state': state},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> update(String id, Map<String, dynamic> updates) async {
    final db = await _db.database;
    await db.update('storyboards', updates, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> updateImageUrl(String id, String imageUrl,
      {String? localPath}) async {
    final db = await _db.database;
    await db.update(
      'storyboards',
      {
        'reference_image_url': imageUrl,
        if (localPath != null) 'reference_image_local_path': localPath,
        'state': 'image_ready',
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Update multiple image URLs (for sequential/group mode).
  /// Also sets the first image as reference_image_url for backward compatibility.
  Future<void> updateImageUrls(String id, List<String> imageUrls) async {
    final db = await _db.database;
    await db.update(
      'storyboards',
      {
        'reference_image_url': imageUrls.isNotEmpty ? imageUrls[0] : null,
        'reference_image_urls':
            imageUrls.isNotEmpty ? jsonEncode(imageUrls) : null,
        'state': 'image_ready',
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}

class VideoClipDao {
  final AppDatabase _db = AppDatabase();

  Future<List<VideoClip>> getByProjectId(String projectId) async {
    final db = await _db.database;
    final maps = await db.query(
      'video_clips',
      where: 'project_id = ?',
      whereArgs: [projectId],
      orderBy: 'created_at',
    );
    return maps.map((m) => VideoClip.fromMap(m)).toList();
  }

  Future<void> insert(VideoClip clip) async {
    final db = await _db.database;
    await db.insert('video_clips', clip.toMap());
  }

  Future<void> update(String id, Map<String, dynamic> updates) async {
    final db = await _db.database;
    await db.update('video_clips', updates, where: 'id = ?', whereArgs: [id]);
  }
}

class FinalCutDao {
  final AppDatabase _db = AppDatabase();

  Future<FinalCut?> getByProjectId(String projectId) async {
    final db = await _db.database;
    final maps = await db.query(
      'final_cuts',
      where: 'project_id = ?',
      whereArgs: [projectId],
    );
    if (maps.isEmpty) return null;
    return FinalCut.fromMap(maps.first);
  }

  Future<void> insert(FinalCut cut) async {
    final db = await _db.database;
    await db.insert('final_cuts', cut.toMap());
  }

  Future<void> update(String id, Map<String, dynamic> updates) async {
    final db = await _db.database;
    await db.update('final_cuts', updates, where: 'id = ?', whereArgs: [id]);
  }
}

class TaskDao {
  final AppDatabase _db = AppDatabase();

  Future<List<Map<String, dynamic>>> getByProjectId(String projectId) async {
    final db = await _db.database;
    return db.query(
      'tasks',
      where: 'project_id = ?',
      whereArgs: [projectId],
      orderBy: 'created_at',
    );
  }

  Future<void> insert(Map<String, dynamic> task) async {
    final db = await _db.database;
    await db.insert('tasks', task);
  }

  Future<void> update(String id, Map<String, dynamic> updates) async {
    final db = await _db.database;
    await db.update('tasks', updates, where: 'id = ?', whereArgs: [id]);
  }
}
