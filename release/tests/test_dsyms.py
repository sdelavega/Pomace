import importlib.util
import contextlib
import io
from pathlib import Path
import subprocess
import unittest
from unittest.mock import call, patch

SPEC = importlib.util.spec_from_file_location("metadata", Path(__file__).resolve().parents[1] / "metadata.py")
metadata = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(metadata)

ARM = "UUID: 12345678-1234-1234-1234-123456789ABC (arm64) /build/PomaceApp\n"
INTEL = "UUID: ABCDEF12-1234-1234-1234-123456789ABC (x86_64) /build/PomaceApp\n"


class DsymTests(unittest.TestCase):
    def test_dwarf_content_requires_compile_unit(self):
        for output in ("", "0x0000000b: DW_TAG_subprogram\n",
                       "DW_TAG_compile_unit_extra\n", "0x0000000b: DW_TAG_compile_unit\n"):
            with self.subTest(output=output), patch.object(metadata.subprocess, "run") as run:
                run.return_value.stdout = output
                if output == "0x0000000b: DW_TAG_compile_unit\n":
                    metadata.check_dwarf_content("arm64", "symbols.dSYM")
                else:
                    with self.assertRaisesRegex(SystemExit, "no DWARF compile units for arm64"):
                        metadata.check_dwarf_content("arm64", "symbols.dSYM")
                run.assert_called_once_with(["dwarfdump", "--debug-info", "symbols.dSYM"],
                                            check=True, capture_output=True, text=True)

    def test_check_dsym_checks_content_before_reporting_success(self):
        for content in ("", "0x0000000b: DW_TAG_compile_unit\n"):
            with self.subTest(content=content), patch.object(metadata.subprocess, "run") as run:
                run.side_effect = [subprocess.CompletedProcess([], 0, stdout=output)
                                   for output in (ARM, ARM, content)]
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    if content:
                        metadata.check_dsym("arm64", "symbols.dSYM", "Pomace")
                    else:
                        with self.assertRaisesRegex(SystemExit, "no DWARF compile units"):
                            metadata.check_dsym("arm64", "symbols.dSYM", "Pomace")
                self.assertEqual(bool(output.getvalue()), bool(content))
                self.assertEqual(run.call_args_list, [
                    call(["dwarfdump", "--uuid", "symbols.dSYM"],
                         check=True, capture_output=True, text=True),
                    call(["dwarfdump", "--uuid", "--arch", "arm64", "Pomace"],
                         check=True, capture_output=True, text=True),
                    call(["dwarfdump", "--debug-info", "symbols.dSYM"],
                         check=True, capture_output=True, text=True)])

    def test_dwarfdump_failures_exit_cleanly(self):
        for error in (subprocess.CalledProcessError(1, ["dwarfdump"]),
                      FileNotFoundError("dwarfdump")):
            for index in range(3):
                with self.subTest(error=type(error).__name__, index=index), \
                        patch.object(metadata.subprocess, "run") as run:
                    run.side_effect = [subprocess.CompletedProcess([], 0, stdout=ARM)] * index + [error]
                    with self.assertRaisesRegex(SystemExit, "^dwarfdump failed for arm64$"):
                        metadata.check_dsym("arm64", "symbols.dSYM", "Pomace")

    def test_matching_uuid(self):
        for arch, output in (("arm64", ARM), ("x86_64", INTEL)):
            with self.subTest(arch=arch):
                self.assertEqual(metadata.matching_dsym_uuid(output, output.replace(output.split()[1], output.split()[1].lower()), arch),
                                 output.split()[1])

    def test_mismatching_uuid(self):
        with self.assertRaisesRegex(SystemExit, "UUID mismatch for arm64"):
            metadata.matching_dsym_uuid(ARM, ARM.replace("12345678", "87654321"), "arm64")

    def test_missing_or_ambiguous_slice(self):
        for output in ("", INTEL, ARM + ARM, ARM + INTEL,
                       ARM.replace("12345678", "invalid")):
            for symbols, binary in ((ARM, output), (output, ARM)):
                with self.subTest(symbols=symbols, binary=binary):
                    with self.assertRaisesRegex(SystemExit, "exactly one DWARF UUID for arm64"):
                        metadata.matching_dsym_uuid(symbols, binary, "arm64")


if __name__ == "__main__":
    unittest.main()
