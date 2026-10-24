import unittest
from core_cache_key import calculate_key


class CoreCacheKeyTests(unittest.TestCase):
    def test_swift_ui_changes_rebuild_the_app_without_invalidating_core(self):
        first = b"100644 blob a\tios/brave-ios/Sources/Web/TabState.swift\0"
        second = b"100644 blob b\tios/brave-ios/Sources/Web/TabState.swift\0"
        self.assertEqual(calculate_key(first, b"sdk", b"recipe"), calculate_key(second, b"sdk", b"recipe"))

    def test_backend_source_changes_invalidate_core(self):
        first = b"100644 blob a\tios/browser/profile.mm\0"
        second = b"100644 blob b\tios/browser/profile.mm\0"
        self.assertNotEqual(calculate_key(first, b"sdk", b"recipe"), calculate_key(second, b"sdk", b"recipe"))

    def test_toolchain_and_recipe_changes_invalidate_core(self):
        self.assertNotEqual(calculate_key(b"", b"sdk1", b"recipe"), calculate_key(b"", b"sdk2", b"recipe"))
        self.assertNotEqual(calculate_key(b"", b"sdk", b"recipe1"), calculate_key(b"", b"sdk", b"recipe2"))


if __name__ == "__main__":
    unittest.main()
