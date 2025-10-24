# Carthage fetch from internal Artifactory

Carthage fetch from internal Artifactory

As Carthage doesn't support private certificate/key pairs, this step is used to dowloand dependencies from internal Artifactory and add them to Carthage. It reads the Cartfile for "binary" dependencies, downloads and extracts to Carthage build directory.