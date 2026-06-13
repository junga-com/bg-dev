# Sandbox Project

This is a bg-dev sandbox project. That means its a collection of project folders that
are worked on together. The typical usecase would be the main target project plus dependencies
that the project uses that you might want to change or debug while working on the target
project.

## Contents

A sandbox has very little content of its own. It is a git repo that has git submodules for
each project it contains.

Think of a sandbox's content as the git submodule configuration. When you commit changes
its the commit id of each submodule that is being committed.


## Sandbox state

cat ./.bg-sp/sandbox.manifest   
[ bg-foo ]
url="git@github.com:junga-com/bg-foo.git"
branch="master"
commit="4839d9abc6940a65a2019d2df899c02eda338b93"

[ bg-anotherSub ]
...


## Operations

You can run bg-dev from the sandbox folder or from any of the submodule folders. Typically
an operation at in sandbox will iterate the submodule projects performing that operation
on each but some operations may implement additional logic to make the combined operation
consistent.

### Adding a subproject to a sandbox

From a sandbox folder...

bg-dev clone [--branch=<branch>] <url> [<folderName>]

bg-dev newProj [--projectType=<type>] <projName>


### Status

From a sandbox or a sub project folder...

bg-dev [status]

To get just a subproject status, from its folder...

bg-dev sdlc [status]


### Syncing Sanbox state
