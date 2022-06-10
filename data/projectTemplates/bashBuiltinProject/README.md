# TODO: replace 'example' with your builtin name.
This project provides the example bash loadable builtin for bash

### DESCRIPTION:
TODO: provide a description of your builtin.

### BUILDING:
run ...
   <projRoot>$ ./configure && make

The ./configure script ..
   1. tries to install build dependencies which are mainly gnu compiler/linker and the bash-builtins package that has the headers
      and example Makefile configured for this machine's architecture.
   2. makes a list of each *.c file in the top level project folder which are each assumed to be builtins
   3. creates the Makefile in the root project folder by copying /usr/lib/bash/Makefile.inc and replacing its example tagets with
      targets that build the builtins found in this project in step 2.

The output <builtin>.so file(s) will be placed in the project's ./bin/ folder.


### TESTING:
You can test the builtin by enabling it in your
interactive shell.
   <projRoot>$ bash # create a new interactive shell to test in case a bug in your builtin exits the shell.
   <projRoot>$ enable -f bin/<builtin>.so <builtin>
   <projRoot>$ <builtin> ....
   <projRoot>$ exit  # go back to your base shell when done testing

If you are using the bg-dev tools to virtually install this project, the project's bin/ folder will be in the BASH_LOADABLES_PATH
so you do not have to include any path like ... "enable -f <builtin>.so <builtin>". This also allows you to test the builtin from
any installed or virtually installed script (probably from a different project).


### INSTALLING:
run ...
   <projRoot>$ make install

It will copy the <builtin>.so files from this project into your host's /usr/lib/bin/ folder. You may need to set BASH_LOADABLES_PATH
in a bash startup file (e.g. /etc/bash.bashrc) to include /usr/lib/bin/ if it does not already. It is a ':' separated list of folders.


### BUILDING A PACKAGE:
You can use the bg-dev command from the bg-dev package to create a package for this project.
run ...
   <projRoot>$ sudo apt install bg-dev
   <projRoot>$ bg-dev buildPkg [deb|rpm]

The package file will be placed in the project root folder
