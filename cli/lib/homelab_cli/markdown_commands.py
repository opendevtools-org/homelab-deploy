from __future__ import annotations

import json
import os
import subprocess

from .docker_names import get_existing_container


def read_commands_from_md(source_path: str) -> list[dict]:
    with open(source_path, "r", encoding="utf-8") as source_file:
        markdown_lines = source_file.readlines()
    blocks = []
    current_user = None
    current_container = None
    current_bash: list[str] = []
    in_bash = False

    for line in markdown_lines:
        if line.startswith("user "):
            if current_user and current_container and current_bash:
                blocks.append(
                    {
                        "User": current_user,
                        "Container": current_container,
                        "Bash": "\n".join(current_bash),
                    }
                )
                current_bash = []
            current_user = line.split()[1].strip()
            in_bash = False
        elif line.startswith("container "):
            current_container = line.split()[1].strip()
            in_bash = False
        elif line.strip().startswith("```bash"):
            in_bash = True
        elif line.strip().startswith("```"):
            in_bash = False
        elif in_bash:
            current_bash.append(line.rstrip())
    if current_user and current_container and current_bash:
        blocks.append(
            {
                "User": current_user,
                "Container": current_container,
                "Bash": "\n".join(current_bash),
            }
        )
    return blocks


def should_execute_command(command: str, populate_config_path: str | None) -> bool:
    if not populate_config_path or not os.path.exists(populate_config_path):
        return True

    with open(populate_config_path, "r", encoding="utf-8") as config_file:
        config = json.load(config_file)

    sections = config.get("sections", {})
    include_list = config.get("include", [])
    exclude_list = config.get("exclude", [])
    if not include_list and not exclude_list:
        return True

    command_sections = []
    for section_name, section_data in sections.items():
        if any(pattern in command for pattern in section_data.get("commands", [])):
            command_sections.append(section_name)
        elif any(file_name in command for file_name in section_data.get("files", [])):
            command_sections.append(section_name)

    if not command_sections:
        return True
    if include_list and not any(section in include_list for section in command_sections):
        return False
    if exclude_list and any(section in exclude_list for section in command_sections):
        return False
    return True


def invoke_commands_from_markdown(
    markdown_file: str,
    version: str,
    populate_config_path: str | None = None,
    verbose: bool = False,
    jwt_env_name: str = "JWT_TOKEN",
    passthrough_users: tuple[str, ...] = (),
) -> None:
    """Run bash blocks from markdown inside `{container}-{version}`.

    User mapping is taken from the markdown `user` line. `root` becomes `--user 0`.
    Optional JWT is read from the JSON config key `jwt` (site-specific file).
    """
    blocks = read_commands_from_md(markdown_file)
    jwt_token = ""
    if populate_config_path and os.path.exists(populate_config_path):
        try:
            with open(populate_config_path, "r", encoding="utf-8") as config_file:
                jwt_token = json.load(config_file).get("jwt", "")
        except (OSError, json.JSONDecodeError):
            pass

    for block in blocks:
        if populate_config_path:
            filtered_commands = [
                command
                for command in block["Bash"].split("\n")
                if command.strip() and should_execute_command(command, populate_config_path)
            ]
            if not filtered_commands:
                print(
                    f"Skipped all commands in {block['Container']} for {block['User']} (filtered by config)"
                )
                continue
            block["Bash"] = "\n".join(filtered_commands)

        container_name = f"{block['Container']}-{version}"
        container_name_ci = get_existing_container(container_name)
        docker_args = ["exec", "-it"]
        if jwt_token:
            docker_args += ["-e", f"{jwt_env_name}={jwt_token}"]
        if block["User"] == "root":
            docker_args += ["--user", "0"]
        elif block["User"] not in passthrough_users:
            docker_args += ["--user", block["User"]]
        docker_args += [container_name_ci, "bash", "-c", block["Bash"]]

        print(f"Running commands in {container_name_ci} as {block['User']}...")
        if verbose:
            print("\n" + "=" * 60)
            print("Commands to execute:")
            print("=" * 60)
            for index, command in enumerate(block["Bash"].split("\n"), 1):
                if command.strip():
                    print(f"{index}. {command}")
            print("=" * 60 + "\n")

        subprocess.run(["docker"] + docker_args, check=False)
