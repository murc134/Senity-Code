import hashlib
import importlib.machinery
import importlib.util
import os
import tempfile
import unittest
import uuid
from pathlib import Path


FILTER_PATH = Path(os.environ.get("SENITY_FILTER_PATH", "/repo/senity-mascot-filter.py"))
HOST_WORKSPACE = r"D:\Host\workspace"
HOST_REPO = r"D:\Host\repo"


class SenityMascotFilterTests(unittest.TestCase):
    def _with_filter(self, env, callback):
        keys = {
            "SENITY_FILE_LINK_FORMAT",
            "SENITY_HOST_TERM_PROGRAM",
            "SENITY_LINK_PATH_MAP",
            "SENITY_STRIP_MOUSE_REPORTING",
            "SENITY_VISIBLE_HOST_PATHS",
            "TERM_PROGRAM",
        }
        old = {key: os.environ.get(key) for key in keys}
        old_cwd = os.getcwd()
        for key in keys:
            os.environ.pop(key, None)
        os.environ.update(env)
        try:
            os.chdir(tempfile.gettempdir())
            name = f"senity_mascot_filter_{uuid.uuid4().hex}"
            loader = importlib.machinery.SourceFileLoader(name, str(FILTER_PATH))
            spec = importlib.util.spec_from_loader(loader.name, loader)
            module = importlib.util.module_from_spec(spec)
            loader.exec_module(module)
            return callback(module)
        finally:
            os.chdir(old_cwd)
            for key, value in old.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value

    def _env(self, **extra):
        env = {
            "SENITY_LINK_PATH_MAP": (
                '[{"container":"/workspace","host":"D:\\\\Host\\\\workspace"},'
                '{"container":"/repo","host":"D:\\\\Host\\\\repo"}]'
            )
        }
        env.update(extra)
        return env

    def _assert_link(self, output, uri):
        uri_bytes = uri.encode("ascii")
        expected_id = hashlib.sha256(uri_bytes).hexdigest()[:16].encode("ascii")
        self.assertIn(b"\x1b]8;id=senity-" + expected_id + b";" + uri_bytes + b"\x1b\\", output)
        self.assertIn(b"\x1b]8;;\x1b\\", output)

    def test_web_link_gets_stable_osc8_id(self):
        def run(mod):
            out = mod.linkify_chunk(b"see https://example.com now")
            self._assert_link(out, "https://example.com")

        self._with_filter(self._env(), run)

    def test_absolute_workspace_file_maps_to_host_file_uri(self):
        def run(mod):
            out = mod.linkify_chunk(b"/workspace/projects/autostart/INITIAL_PROMPT.md")
            self._assert_link(out, "file:///D:/Host/workspace/projects/autostart/INITIAL_PROMPT.md")

        self._with_filter(self._env(), run)

    def test_relative_filename_searches_project_roots(self):
        def run(mod):
            out = mod.linkify_chunk(b"INITIAL_PROMPT.md")
            self._assert_link(out, "file:///D:/Host/workspace/projects/autostart/INITIAL_PROMPT.md")

        self._with_filter(self._env(), run)

    def test_relative_folder_with_slash_maps_to_host_folder_uri(self):
        def run(mod):
            out = mod.linkify_chunk(b"projects/autostart/")
            self._assert_link(out, "file:///D:/Host/workspace/projects/autostart")

        self._with_filter(self._env(), run)

    def test_ansi_split_path_keeps_colored_label_clickable(self):
        def run(mod):
            out = mod.linkify_chunk(
                b"\x1b[94m/workspace/projects/\x1b[0m\x1b[94mautostart/INITIAL_PROMPT.md\x1b[0m"
            )
            self._assert_link(out, "file:///D:/Host/workspace/projects/autostart/INITIAL_PROMPT.md")
            self.assertIn(b"/workspace/projects/\x1b[0m\x1b[94mautostart/INITIAL_PROMPT.md", out)

        self._with_filter(self._env(), run)

    def test_warp_renders_host_path_visibly_for_native_file_detection(self):
        def run(mod):
            out = mod.linkify_chunk(b"/workspace/projects/autostart/INITIAL_PROMPT.md")
            self._assert_link(out, "file:///D:/Host/workspace/projects/autostart/INITIAL_PROMPT.md")
            self.assertIn(b"D:\\Host\\workspace\\projects\\autostart\\INITIAL_PROMPT.md", out)
            self.assertNotIn(b"/workspace/projects/autostart/INITIAL_PROMPT.md\x1b]8;;", out)

        self._with_filter(self._env(SENITY_HOST_TERM_PROGRAM="WarpTerminal"), run)

    def test_visible_host_path_fallback_can_be_disabled(self):
        def run(mod):
            out = mod.linkify_chunk(b"/workspace/projects/autostart/INITIAL_PROMPT.md")
            self._assert_link(out, "file:///D:/Host/workspace/projects/autostart/INITIAL_PROMPT.md")
            self.assertIn(b"/workspace/projects/autostart/INITIAL_PROMPT.md", out)
            self.assertNotIn(b"D:\\Host\\workspace", out)

        self._with_filter(
            self._env(SENITY_HOST_TERM_PROGRAM="WarpTerminal", SENITY_VISIBLE_HOST_PATHS="0"),
            run,
        )

    def test_vscode_file_link_format_includes_line_and_column(self):
        def run(mod):
            out = mod.linkify_chunk(b"INITIAL_PROMPT.md:12:3")
            self._assert_link(out, "vscode://file/D:/Host/workspace/projects/autostart/INITIAL_PROMPT.md:12:3")

        self._with_filter(self._env(SENITY_FILE_LINK_FORMAT="vscode"), run)

    def test_warp_mouse_reporting_enable_sequences_are_removed(self):
        def run(mod):
            out = mod.linkify_chunk(b"\x1b[?1000h\x1b[?1006hINITIAL_PROMPT.md")
            self.assertNotIn(b"\x1b[?1000h", out)
            self.assertNotIn(b"\x1b[?1006h", out)
            self._assert_link(out, "file:///D:/Host/workspace/projects/autostart/INITIAL_PROMPT.md")

        self._with_filter(self._env(SENITY_HOST_TERM_PROGRAM="WarpTerminal"), run)

    def test_non_warp_mouse_reporting_enable_sequences_are_kept(self):
        def run(mod):
            out = mod.linkify_chunk(b"\x1b[?1000hINITIAL_PROMPT.md")
            self.assertIn(b"\x1b[?1000h", out)
            self._assert_link(out, "file:///D:/Host/workspace/projects/autostart/INITIAL_PROMPT.md")

        self._with_filter(self._env(SENITY_HOST_TERM_PROGRAM="WindowsTerminal"), run)

    def test_existing_osc8_link_is_preserved_and_later_path_is_linkified(self):
        existing = b"\x1b]8;;https://already.example\x1b\\already\x1b]8;;\x1b\\"

        def run(mod):
            out = mod.linkify_chunk(existing + b" /workspace/projects/autostart/INITIAL_PROMPT.md")
            self.assertIn(existing, out)
            self.assertEqual(out.count(b"https://already.example"), 1)
            self._assert_link(out, "file:///D:/Host/workspace/projects/autostart/INITIAL_PROMPT.md")

        self._with_filter(self._env(), run)


if __name__ == "__main__":
    unittest.main()
