import '../database.dart';
import '../../models/models.dart';

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
    await db.delete('projects', where: 'id = ?', whereArgs: [id]);
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
    await db.insert('briefs', brief.toMap());
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
    await db.insert('scripts', script.toMap());
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
      await db.insert('assets', asset.toMap());
    }
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
      await db.insert('storyboards', sb.toMap());
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
