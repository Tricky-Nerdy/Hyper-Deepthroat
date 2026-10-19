extends RefCounted
## Pure platform path policy. Mobile/browser packages cannot store user content beside the executable.


static func root(platform: String, in_editor: bool, project_dir: String, executable: String, user_dir: String) -> String:
	if in_editor:
		return project_dir.get_base_dir().get_base_dir()
	if platform in ["Android", "iOS", "Web"]:
		return user_dir
	return executable.get_base_dir()
