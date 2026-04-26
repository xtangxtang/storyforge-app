import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class AppDatabase {
  static final AppDatabase _instance = AppDatabase._internal();
  static Database? _database;

  AppDatabase._internal();

  factory AppDatabase() => _instance;

  Future<Database> get database async {
    _database ??= await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'storyforge.db');

    return openDatabase(
      path,
      version: 1,
      onCreate: _onCreate,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        user_id TEXT,
        state TEXT NOT NULL DEFAULT 'planning',
        template_style TEXT,
        template_script TEXT,
        template_storyboard TEXT,
        budget_limit REAL,
        budget_used REAL NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE briefs (
        project_id TEXT PRIMARY KEY REFERENCES projects(id),
        genre TEXT,
        duration INTEGER,
        aspect_ratio TEXT,
        mood TEXT,
        visual_style TEXT,
        story_outline TEXT,
        created_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE scripts (
        project_id TEXT PRIMARY KEY REFERENCES projects(id),
        content TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE assets (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL REFERENCES projects(id),
        type TEXT NOT NULL,
        name TEXT NOT NULL,
        description TEXT,
        prompt TEXT,
        reference_image_url TEXT,
        state TEXT NOT NULL DEFAULT 'pending',
        created_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE storyboards (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL REFERENCES projects(id),
        scene_num INTEGER NOT NULL,
        shot_num INTEGER NOT NULL,
        shot_type TEXT,
        camera_move TEXT,
        description TEXT,
        first_frame_prompt TEXT,
        video_prompt TEXT,
        duration INTEGER,
        assets TEXT,
        state TEXT NOT NULL DEFAULT 'pending',
        created_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE video_clips (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL REFERENCES projects(id),
        storyboard_id TEXT NOT NULL,
        video_url TEXT,
        state TEXT NOT NULL DEFAULT 'generating',
        is_selected INTEGER NOT NULL DEFAULT 0,
        error_reason TEXT,
        version INTEGER NOT NULL DEFAULT 1,
        created_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE final_cuts (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL REFERENCES projects(id),
        video_url TEXT,
        video_clip_ids TEXT,
        state TEXT NOT NULL DEFAULT 'rendering',
        created_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE tasks (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL REFERENCES projects(id),
        type TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT 'queued',
        result TEXT,
        error TEXT,
        retry_count INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        finished_at INTEGER
      )
    ''');
  }

  Future<void> close() async {
    final db = await database;
    await db.close();
  }

  Future<void> reset() async {
    final db = await database;
    for (final table in [
      'tasks', 'video_clips', 'final_cuts', 'storyboards',
      'assets', 'scripts', 'briefs', 'projects',
    ]) {
      await db.execute('DROP TABLE IF EXISTS $table');
    }
    await _onCreate(db, 1);
  }
}
