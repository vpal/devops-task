import unittest

from helloapp.app import hello_world


class TestHello(unittest.TestCase):
    def test_hello(self):
        self.assertIn("Hello", hello_world(), "Endpoint is not polite enough.")
