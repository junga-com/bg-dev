# bg-dev

| :warning: WARNING          |
|:---------------------------|
| This library is in a pre-release state. If you try this project out, I would love to here about your experience. See the [bg-core readme.md](https://github.com/junga-com/bg-core) for installation instructions. 

## Overview
This is a tool to help create and mantain software packages. The central idea is that a folder that follows some conventions can contain assets of various types which can be built into a package for distribution to host computers.

This package depends on bg-core. bg-core is a library that scripts can use to leverage common features. bg-dev is a development time tool that only gets installed when developing packages and bg-core is a runtime tool that typically gets installed alongside the packages you create on the target user's host. The package you create with bg-dev does not need to depend on bg-core but it often will so that it can take advantage of features provided by bg-core.

## Projects Type Concept
bg-dev works with various project types that form a hierarchy. At the base of the hierarchy is a git controlled folder. Each project type requires certain features to be present and enables functionality specific to its type. Project types are implemented as bash objects ([see bg-core plugins](https://github.com/junga-com/bg-core#Object-Oriented-Bash)).

Operations on projects can be polymorphic meaning that for example, the `publish` operation will do the thing appropriate for the type of project.  


## Sandbox Projects

A sandbox folder is a collection of other types of project folders. The purpose of a sandbox folder is to gather a set of projects that are related so that we can perform operations on the whole set of package folders at once.  Typically, a sandbox contains a main project that is the focus of the sandbox and any other projects that the main target project depends on.

This makes it easier when a change in the target project requires coordinated changes in its dependent packages. In particular the SDLC (software development life cycle) operations of cloning, changing, testing, committing, pushing, publishing can be done on a sandbox and it will do the right thing for each project based on whether or not changes were made and policies defined for each project.

A sandbox is also useful for a set of packages related in other ways. For example, a sandbox could be created for all the projects maintained by the same department so that testing or other operations could be executed.

A project can be included in many different sandbox projects.

## Package Projects
A package folder contains content that builds into a deb or rpm package which will be installed to provide features on a target device.

## Assets Concept
Assets are features that are added to package projects. Typically assets get installed on the target host the package is installed on and what exactly it means to be installed on the target host varies from asset type to asset type.

There is builtin support for a number of asset types and support for new asset types can be added by creating an asset type [plugin](https://github.com/junga-com/bg-core#Plugins) in another package.

Builtin Asset Types:
 * commands - an executable file (including scripts) that can be invoked on the command line.
 * libraries - a file containing functions that can be used by commands or other libraries.
 * plugins - a file that extends some mechanism
 ** collect plugins - defines a set of some information on the target host that will be periodically snapshotte. -- typically used for a central management system.
 ** standards plugins - a file that uses the creq declarative configuration language to describe some set of baseline configurations for which the host can be tested for compliance.
 ** config plugins - a file that uses the creq declarative configuration language to describe some set of baseline configurations that can be used to configure the target host to be compliant.
 ** RBACPermission plugin - a file that describes a set of sudo capabilities that a user can possess by being assigned the permission.
 * data - files that will be copied to the target host.
 * templates - files that can be expanded by commands on the target host.
 * manpage - a file containing a manpage content. Note that typically most manpages that a package project should have will be automatically generated from the source of other assets. For example each BASH script command will have a man page generated from the comments contained in the script.
 * daemon - an executable file (including scripts) that complies with a standard that allows it to be controlled by a daemon management system like systemd or others.
 * cron - a file that causes the host to run commands periodically on a schedule
 * etc - a configuration file that will be copied to the /etc/ folder hierarchy on the target host.

Asset types are hierarchical. For example the asset type `lib` is treated as a generic library that could be a interpreted or compiled. `lib.script` is a library that could be written in any interpreted language. `lib.script.awk` is a library written in the awk language.

The hierarchical nature of asset types allows generic handling of certain assets and also specific handling of types that need it.

For example the install operation for `lib` copies the library to /usr/lib but if the asset type matches the more specific `lib.script.awk` it will copy it to /usr/share/awk

The three main operations for assets are `install`, `find`, and `addNew`. `find` will list all the assets of that type contained in a project folder.

## In-place Development

The bg-debugCntr command enables projects to be developed in-place. This means that as soon as you add an asset to a project or changes an existing asset, you can test the feature that the asset provides.

`bg-debugCntr vinstall <project>` will 'virtually install the project'. bg-debugCntr must be sourced into the terminal environment where you are working and it will remind you of that if you forget. It will modify the environment for that terminal bash process to put the project folders first so that commands typed in the terminal will be found in those folder before any same named commands installed on the host. It does similar things for importing libraries, finding man pages, etc... so that it is as close to the installed environment as possible.

Note that in order to source bg-debugCntr or access any of the development time features supported in bg-core, the host you are working on must have a file `/etc/bgHostProductionMode` which contains the single line `mode=development`. This prevents developement time features from being used to circumvent security on a host that you do not have privilege to create or modify that file.

## Debugging

bg-dev contains a full bash script debugger which itself is written in bash. You can invoke it by prefixing your script command line with `bgdb ` or by inserting the line `bgtraceBreak` in your script or in several other ways controlled by `bg-debugCntr debugger ...`

By default the debugger UI will open in a new terminal window but if you are running on a remote server via ssh, it will reuse your existing terminal by using the page flip facility.

If you have the bg-atom-bash-debugger package installed in the Atom code editor and an instance of Atom is open on the same project folder, the debugger will attach to Atom so that you can debug in that code editor.

## BGTracing

I find it easier sometimes to add temporary trace statements to debug scripts rather than step through the debugger. Also various features provided by bg-core will write information to the bgtrace destination if its enabled providing meta data information for the script run.

`bg-debugCntr trace on:` will turn on tracing to the default destination which is /tmp/bgtrace.out. I typically open a separate terminal window and `tail -f /tmp/bgtrace.out`. The bash completion for that bg-debugCntr command will show you other options for the bgtrace destination.

There are a whole family of functions that begin with bgtrace*. Most write some information to the bgtrace destination so that you can monitor your script code but some like bgtraceBreak do other things. Typically any bgtrace* function will be a noop (i.e. do nothing) if a bgtrace destination is not set (i.e. tracing is enabled).

The most common bgtrace* functions are...

* **bgtraceVars** : list variable names and the values of each will be printed to bgtrace destination in a way that makes sense for it. There are various options to control the formatting.
* **bgtraceParams** : put this at the top of a function body with no arguments and it will print the function name and dollar arguments being passed to it.
* **bgtraceBreak** : if tracing is enabled when this line is encountered it will break in the debugger. If the debugger is not already active it will enable the default debugger UI.
* **bgtraceXTrace on/off** : inbetween on and off calls the bash facility to print every command that it executes will send its output to the bgtrace destination.
* **bgtraceStack** : print the current stack trace to bgtrace destination
* **bgtracePSTree** : print the current process tree of the script to bgtrace destination

Note also that from the integrated debugger's cmd line (as opposed to the Atom editor debugger front end) you can invoke these bgtrace* commands to inspect various aspects of the run state.

## Funcman

Funcman is a system that gleans documentation from scripts. It currently works with bash and awk files. Every command, library and library function will have documentation created. If a comment block exists matching a certain convention for one of those things, the information in that block will be used to make the information better.

The `bg-dev funcman test ...` command can be used to test content for a particular feature to see how it formats.

`bg-debugCntr vinstall ...` will generate the funcman content. You can also call `bg-debugCntr vinstall` with no project folders specified at any time to update the funcman content (and other features that need to be generated)

Currently funcman generates man pages but its written to be able to generate different documentation formats. I intend to have it support generating linked HTML content for publishing on a web site.

## Unittests

`bg-dev tests run` will batch run all the unit tests from the project in the PWD and report on how many pass, fail, or are in error.

## FreshVMs

`bg-dev tests FreshVMs ...` is a system for creating virtual machines running various OS versions that can be used to test projects in those environments.

Its important to use this to test even your primary development environment because you have configuration on your host that is required by a project but not declared in your project. For example your project might require a package be installed but because you already had it installed you did not think to list it as a dependency.

The VM instances that are created will automatically have the vinstalled sandbox that you are working in shared with the VM so that you can vinstall it in the VM and test there.

To support a new OS or OS version, you can create or obtain a cloud image of that OS version and put it in ~/.bg/cache/bg-dev_vmImages/osCloudImages/ and then add a line in ~/.bg/cache/bg-dev_vmImages/osCloudImages/index.dat to represent it. Any debian or redhat derivative should work without further work.
