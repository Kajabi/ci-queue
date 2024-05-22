import os
import glob

try:
    import setuptools as setuplib
except ImportError:
    import distutils.core as setuplib

SCRIPTS_PATH = 'ciqueue/redis'


def get_lua_scripts():
    if not os.path.exists(SCRIPTS_PATH):
        os.makedirs(SCRIPTS_PATH)

    paths = []

    if not os.path.exists(SCRIPTS_PATH):
        os.makedirs(SCRIPTS_PATH)

    for path in glob.glob(os.path.join(
            os.path.dirname(__file__), '../redis/*.lua')):
        filename = os.path.basename(path)

        destination_path = os.path.join(os.getcwd(), SCRIPTS_PATH, filename)
        with open(destination_path, 'w+') as lua_file:
            lua_file.write("-- AUTOGENERATED FILE DO NOT EDIT DIRECTLY\n")
            lua_file.write(open(path).read())
        paths.append(destination_path)

    return paths


setuplib.setup(
    name='ciqueue',
    version='0.1',
    packages=['ciqueue', 'ciqueue._pytest'],
    install_requires=[
        'dill>=0.2.7',
        'pytest>=2.7',
        'redis>=2.10.5',
        'tblib>=1.3.2',
        'uritools>=2.0.0',
        'future>=0.16.0'
    ],
    extras_require={
        'test': [
            'tox==4.6.4',
            'shopify_python==0.5.3',
            'pycodestyle==2.10.0',
        ]
    },
    package_data={'': get_lua_scripts()},
    include_package_data=True,
)
