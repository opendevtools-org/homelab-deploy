"""Generic helpers for Hub/PKM site CLIs (no company defaults)."""

from .color import color_text, colors_enabled
from .compose_hash import calculate_file_hash, check_compose_file_changes
from .docker_names import get_existing_container
from .github_api import github_request, tag_commit, version_from_tag
from .markdown_commands import (
    invoke_commands_from_markdown,
    read_commands_from_md,
    should_execute_command,
)

__all__ = [
    "calculate_file_hash",
    "check_compose_file_changes",
    "color_text",
    "colors_enabled",
    "get_existing_container",
    "github_request",
    "invoke_commands_from_markdown",
    "read_commands_from_md",
    "should_execute_command",
    "tag_commit",
    "version_from_tag",
]
