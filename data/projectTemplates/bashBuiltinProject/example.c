// example builtin to start new builtins
// TODO: search and replace every word "example" with your builtin's name

#include <config.h>

#if defined (HAVE_UNISTD_H)
#  include <unistd.h>
#endif
#include "bashansi.h"
#include <stdio.h>
#include <errno.h>
#include <regex.h>

#include "loadables.h"
#include "variables.h"
//#include "execute_cmd.h"
#include <stdarg.h>

#if !defined (errno)
extern int errno;
#endif


// TODO: this is the function that is called when your builtin is invoked
int example_builtin (WORD_LIST* list)
{
	if (!list || !list->word) {
		printf ("Error - <cmd> is a required argument. See usage..\n\n");
		builtin_usage();
		return (EX_USAGE);
	}

	printf("this is just an example builtin\n");

	return (EXECUTION_SUCCESS);
}


// This function is called when `example' is enabled and loaded from the shared object. (i.e. enable -f example.so example)
// If this function returns 0, the load fails.
int example_builtin_load (char* name)
{
	printf("example builtin loading\n");
	return (1);
}

// This function is called when `example' is disabled. (i.e. enable -d example) */
void example_builtin_unload (char* name)
{
	printf("example builtin unloading\n");
}

// This is the help text (i.e. help example)
char *example_doc[] = {
	"TODO: write a short description of this example builtin",
	"",
	"TODO: write a longer, more detailed description and instructions",
	(char *)NULL
};

// This is the structure that registers this builtin with bash
// TODO: write the synopsis line below
struct builtin example_struct = {
	"example",           // builtin name
	example_builtin,     // function implementing the builtin
	BUILTIN_ENABLED,     // initial flags for builtin
	example_doc,         // array of long documentation strings.
	"example <cmd> ",    // usage synopsis; becomes short_doc
	0                    // reserved for internal use
};
