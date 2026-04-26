import 'package:flutter/material.dart';
import '../db/dao/dao.dart';
import '../models/models.dart';
import 'create_project_screen.dart';
import 'project_detail_screen.dart';

class ProjectListScreen extends StatefulWidget {
  const ProjectListScreen({super.key});

  @override
  State<ProjectListScreen> createState() => _ProjectListScreenState();
}

class _ProjectListScreenState extends State<ProjectListScreen> {
  final _projectDao = ProjectDao();
  List<Project> _projects = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadProjects();
  }

  Future<void> _loadProjects() async {
    final projects = await _projectDao.getAll();
    setState(() {
      _projects = projects;
      _loading = false;
    });
  }

  Future<void> _deleteProject(Project project) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除项目 "${project.name}" 吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _projectDao.delete(project.id);
      await _loadProjects();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Storyforge')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _projects.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.movie_creation, size: 64, color: Colors.grey),
                      const SizedBox(height: 16),
                      const Text('暂无项目', style: TextStyle(color: Colors.grey)),
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        onPressed: () => _navigateToCreate(),
                        icon: const Icon(Icons.add),
                        label: const Text('创建新项目'),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: _projects.length,
                  itemBuilder: (context, index) {
                    final project = _projects[index];
                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: ListTile(
                        leading: const Icon(Icons.movie, size: 36),
                        title: Text(project.name),
                        subtitle: Text(_stateLabel(project.state)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Chip(
                              label: Text(
                                _stateLabel(project.state),
                                style: const TextStyle(fontSize: 12),
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _deleteProject(project),
                            ),
                          ],
                        ),
                        onTap: () => _navigateToProject(project),
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _navigateToCreate,
        tooltip: '创建新项目',
        child: const Icon(Icons.add),
      ),
    );
  }

  String _stateLabel(String state) {
    const labels = {
      'planning': '策划',
      'scripting': '编剧',
      'asseting': '资产',
      'storyboarding': '分镜',
      'generating': '生成视频',
      'cutting': '剪辑',
      'done': '完成',
    };
    return labels[state] ?? state;
  }

  void _navigateToCreate() async {
    final created = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const CreateProjectScreen()),
    );
    if (created == true) {
      await _loadProjects();
    }
  }

  void _navigateToProject(Project project) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ProjectDetailScreen(project: project),
      ),
    );
    await _loadProjects();
  }
}
