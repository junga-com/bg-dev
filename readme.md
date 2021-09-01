# bg-dev

| :warning: WARNING          |
|:---------------------------|
| This library is in a pre-release state. The readme file is full of mini tutorials that demonstrate most of the features. If you try any out, I would love to here about your experience.
I have only tested on Ubuntu 20.04 but it should work in other distributions and versions without major change.
I am not building the packages for this library yet. To test it, clone bg-core and bg-dev into a new folder (for example ~/bg-sandbox/) and virtually install with the bg-debugCntr command like...
 ~/$ `mkdir bg-sandbox; cd bg-sandbox`
 ~/bg-sandbox$ `git clone git@github.com:junga-com/bg-dev.git`
 ~/bg-sandbox$ `git clone git@github.com:junga-com/bg-core.git`
 ~/bg-sandbox$ `source ~/bg-sandbox/bg-dev/bg-debugCntr; bg-debugCntr vinstall ~/bg-sandbox/; bg-debugCntr trace on:`

This is a tool to help build software packages. The central idea is that a folder that follows some conventions can contain assets of various types which can be built into a package for distribution.

This package depends on bg-core. bg-core is a library that scripts can use to leverage common features. bg-dev is a development time tool that only gets installed when developing packages and bg-core is a runtime tool that typically gets installed alongside the packages you create on the target user's host. The package you create with bg-dev does not need to depend on bg-core but it often will so that it can take advantage of features provided by bg-core.


## Sandbox and Package Folders Concept
bg-dev works with two types of project data folders.  A package folder contains content that builds into a deb or rpm package which will be installed to provide features on a target device.

A sandbox folder is a collection of package folders as git submodules. The purpose of a sandbox folder is to gather a set of package folders that are related so that we can perform operations on the whole set of package folders at once.  Typically, a sandbox contains a target package folder and any other package folder that the target depends on. This makes it easier when a change in the target package requires coordinated changes in its dependent packages. It can also be a set of packages related in other way. For example, all the package projects maintained by the same department. A package folder can be included in many different sandbox folders.


## Assets Concept
Assets are features that are added to package projects that get installed on the target host the package is installed on. There are different types of assets.

There is builtin support for a number of asset types and support for new asset types can be added by creating an asset type plugin.

Builtin Asset Types:
 * commands - an executable file (including scripts) that can be invoked on the command line.
 * libraries - a file containing functions that can be used by commands or other libraries.
 * plugins - a file that extends some mechanism
 ** collect plugins - defines a set of some information on the target host that will be periodically snapshotte. -- typically used for a central management system.
 ** standards plugins - a file that uses the creq declarative configuration language to describe some set of baseline configurations for which the host can be tested for compliance.
 ** config plugins - a file that uses the creq declarative configuration language to describe some set of baseline configurations that can be used to configure the target host to be compliant.
 ** RBACPermission plugin - a file that describes a set of sudo capabilities that a user can possess by being assigned the permission.
 * data - files that will be copied to the target host.
 * templates - template files that follow a naming convention that will be copied to the target host and registered to be discoverable by the template system.
 * manpage - a file containing a manpage content. Note that typically most manpages that a package project should have will be automatically generated from the source of other assets. For example each BASH script command will have a man page generated from the comments contained in the script.
 * daemon - an executable file (including scripts) that complies with a standard that allows it to be controlled by a daemon management system like systemd or others.
 * cron - a file that causes the host to run commands periodically on a schedule
 * etc - a configuration file that will be copied to the /etc/ folder hierarchy on the target host.

Asset types are hierarchical. For example the asset type "lib" is treated as a generic library that could be written in any language whereas "lib.awk" is a library written in the awk language. This allows generic handling of library assets but when some assets in the type needs different handling (like awk library files being placed in a awk specific location) a sub-type can be created.

## Features
 * bg-debugCntr - this script gets sourced into a bash shell terminal to make it a test and debug environment. It only affects the terminal that you source it in.
 * [vinstall](#Virtual-Installing): `bg-debugCntr vinstall ...` Develop package assets inplace without having to build and install the package.
 * BASH debugger - stop your script at a breakpoint, examine its variables and step through.
 * tracing - `bg-debugCntr trace ...` add bgtrace* statements to your script to monitor what it does. The output can be turned on and off and directed to various places.
 * manifest - `bg-dev manifest ...` The package manifest is a list of assets that the package provides.
 * funcman - `bg-dev funcman ...` generate documentation from the asset source files. Running vinstall will update the generated files so that you can see how the documentation looks while you develop the assets
 * unittests - create and manage unit tests alongside your asset code. Unittest files are simple bash scripts that can exercise commands and other assets written in any language.
