class Project {
  final String id;
  final String name;
  final String? userId;
  final String state;
  final String? templateStyle;
  final String? templateScript;
  final String? templateStoryboard;
  final double? budgetLimit;
  final double budgetUsed;
  final int createdAt;
  final int updatedAt;

  Project({
    required this.id,
    required this.name,
    this.userId,
    this.state = 'planning',
    this.templateStyle,
    this.templateScript,
    this.templateStoryboard,
    this.budgetLimit,
    this.budgetUsed = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Project.fromMap(Map<String, dynamic> map) {
    return Project(
      id: map['id'] as String,
      name: map['name'] as String,
      userId: map['user_id'] as String?,
      state: map['state'] as String? ?? 'planning',
      templateStyle: map['template_style'] as String?,
      templateScript: map['template_script'] as String?,
      templateStoryboard: map['template_storyboard'] as String?,
      budgetLimit: map['budget_limit'] != null
          ? (map['budget_limit'] as num).toDouble()
          : null,
      budgetUsed: (map['budget_used'] as num? ?? 0).toDouble(),
      createdAt: map['created_at'] as int? ?? 0,
      updatedAt: map['updated_at'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'user_id': userId,
      'state': state,
      'template_style': templateStyle,
      'template_script': templateScript,
      'template_storyboard': templateStoryboard,
      'budget_limit': budgetLimit,
      'budget_used': budgetUsed,
      'created_at': createdAt,
      'updated_at': updatedAt,
    };
  }
}

class Brief {
  final String projectId;
  final String? genre;
  final int? duration;
  final String? aspectRatio;
  final String? mood;
  final String? visualStyle;
  final String? storyOutline;
  final int createdAt;

  Brief({
    required this.projectId,
    this.genre,
    this.duration,
    this.aspectRatio,
    this.mood,
    this.visualStyle,
    this.storyOutline,
    required this.createdAt,
  });

  factory Brief.fromMap(Map<String, dynamic> map) {
    return Brief(
      projectId: map['project_id'] as String,
      genre: map['genre'] as String?,
      duration: map['duration'] as int?,
      aspectRatio: map['aspect_ratio'] as String?,
      mood: map['mood'] as String?,
      visualStyle: map['visual_style'] as String?,
      storyOutline: map['story_outline'] as String?,
      createdAt: map['created_at'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'project_id': projectId,
      'genre': genre,
      'duration': duration,
      'aspect_ratio': aspectRatio,
      'mood': mood,
      'visual_style': visualStyle,
      'story_outline': storyOutline,
      'created_at': createdAt,
    };
  }
}

class Script {
  final String projectId;
  final String content;
  final int createdAt;
  final int updatedAt;

  Script({
    required this.projectId,
    required this.content,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Script.fromMap(Map<String, dynamic> map) {
    return Script(
      projectId: map['project_id'] as String,
      content: map['content'] as String,
      createdAt: map['created_at'] as int? ?? 0,
      updatedAt: map['updated_at'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'project_id': projectId,
      'content': content,
      'created_at': createdAt,
      'updated_at': updatedAt,
    };
  }
}

class Scene {
  final int sceneNum;
  final String location;
  final String description;
  final String action;
  final List<String> dialogue;
  final int duration;

  Scene({
    required this.sceneNum,
    required this.location,
    required this.description,
    required this.action,
    this.dialogue = const [],
    required this.duration,
  });

  factory Scene.fromMap(Map<String, dynamic> map) {
    return Scene(
      sceneNum: map['scene_num'] as int? ?? 0,
      location: map['location'] as String? ?? '',
      description: map['description'] as String? ?? '',
      action: map['action'] as String? ?? '',
      dialogue: (map['dialogue'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      duration: map['duration'] as int? ?? 0,
    );
  }
}

class Asset {
  final String id;
  final String projectId;
  final String type;
  final String name;
  final String? description;
  final String? prompt;
  final String? referenceImageUrl;
  final String state;
  final int createdAt;

  Asset({
    required this.id,
    required this.projectId,
    required this.type,
    required this.name,
    this.description,
    this.prompt,
    this.referenceImageUrl,
    this.state = 'pending',
    required this.createdAt,
  });

  factory Asset.fromMap(Map<String, dynamic> map) {
    return Asset(
      id: map['id'] as String,
      projectId: map['project_id'] as String,
      type: map['type'] as String,
      name: map['name'] as String,
      description: map['description'] as String?,
      prompt: map['prompt'] as String?,
      referenceImageUrl: map['reference_image_url'] as String?,
      state: map['state'] as String? ?? 'pending',
      createdAt: map['created_at'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'project_id': projectId,
      'type': type,
      'name': name,
      'description': description,
      'prompt': prompt,
      'reference_image_url': referenceImageUrl,
      'state': state,
      'created_at': createdAt,
    };
  }
}

class Storyboard {
  final String id;
  final String projectId;
  final int sceneNum;
  final int shotNum;
  final String? shotType;
  final String? cameraMove;
  final String? description;
  final String? firstFramePrompt;
  final String? videoPrompt;
  final int? duration;
  final String? assets;
  final String state;
  final int createdAt;

  Storyboard({
    required this.id,
    required this.projectId,
    required this.sceneNum,
    required this.shotNum,
    this.shotType,
    this.cameraMove,
    this.description,
    this.firstFramePrompt,
    this.videoPrompt,
    this.duration,
    this.assets,
    this.state = 'pending',
    required this.createdAt,
  });

  factory Storyboard.fromMap(Map<String, dynamic> map) {
    return Storyboard(
      id: map['id'] as String,
      projectId: map['project_id'] as String,
      sceneNum: map['scene_num'] as int? ?? 0,
      shotNum: map['shot_num'] as int? ?? 0,
      shotType: map['shot_type'] as String?,
      cameraMove: map['camera_move'] as String?,
      description: map['description'] as String?,
      firstFramePrompt: map['first_frame_prompt'] as String?,
      videoPrompt: map['video_prompt'] as String?,
      duration: map['duration'] as int?,
      assets: map['assets'] as String?,
      state: map['state'] as String? ?? 'pending',
      createdAt: map['created_at'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'project_id': projectId,
      'scene_num': sceneNum,
      'shot_num': shotNum,
      'shot_type': shotType,
      'camera_move': cameraMove,
      'description': description,
      'first_frame_prompt': firstFramePrompt,
      'video_prompt': videoPrompt,
      'duration': duration,
      'assets': assets,
      'state': state,
      'created_at': createdAt,
    };
  }
}

class VideoClip {
  final String id;
  final String projectId;
  final String storyboardId;
  final String? videoUrl;
  final String state;
  final bool isSelected;
  final String? errorReason;
  final int version;
  final int createdAt;

  VideoClip({
    required this.id,
    required this.projectId,
    required this.storyboardId,
    this.videoUrl,
    this.state = 'generating',
    this.isSelected = false,
    this.errorReason,
    this.version = 1,
    required this.createdAt,
  });

  factory VideoClip.fromMap(Map<String, dynamic> map) {
    return VideoClip(
      id: map['id'] as String,
      projectId: map['project_id'] as String,
      storyboardId: map['storyboard_id'] as String,
      videoUrl: map['video_url'] as String?,
      state: map['state'] as String? ?? 'generating',
      isSelected: (map['is_selected'] as int? ?? 0) != 0,
      errorReason: map['error_reason'] as String?,
      version: map['version'] as int? ?? 1,
      createdAt: map['created_at'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'project_id': projectId,
      'storyboard_id': storyboardId,
      'video_url': videoUrl,
      'state': state,
      'is_selected': isSelected ? 1 : 0,
      'error_reason': errorReason,
      'version': version,
      'created_at': createdAt,
    };
  }
}

class FinalCut {
  final String id;
  final String projectId;
  final String? videoUrl;
  final String? videoClipIds;
  final String state;
  final int createdAt;

  FinalCut({
    required this.id,
    required this.projectId,
    this.videoUrl,
    this.videoClipIds,
    this.state = 'rendering',
    required this.createdAt,
  });

  factory FinalCut.fromMap(Map<String, dynamic> map) {
    return FinalCut(
      id: map['id'] as String,
      projectId: map['project_id'] as String,
      videoUrl: map['video_url'] as String?,
      videoClipIds: map['video_clip_ids'] as String?,
      state: map['state'] as String? ?? 'rendering',
      createdAt: map['created_at'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'project_id': projectId,
      'video_url': videoUrl,
      'video_clip_ids': videoClipIds,
      'state': state,
      'created_at': createdAt,
    };
  }
}
