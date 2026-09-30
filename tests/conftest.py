import os
import sys

# Make app/app.py importable from the tests folder
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))
