

# Library
# This library is test input for funcman.
# In this file, we will put an example of each supported syntax. A unit test will render this
# file to document the rendered man page syntax



# usage: testFunc1 [-q|-v] <one> <two>
# A short description.
# More info about **the** function.
# Some Sub Heading:
#
# Params:
#    <one> : this is that
#    <two> : this is that
# Options:
#    -q : quiet. show less output
#    -v : verbose. show more output
# See Also:
#    man(3) foo
#    bar -- a related function in some way
function testFunc1() {
	:
}



# usage: testFunc1 [-q|-v] <one> <two>
# A short description.
# More info about **the** function.
# Some Sub Heading:
#
# Params:
#    <one> : this is that
#    <two> : this is that
# Options:
#    -q : quiet. show less output
#    -v : verbose. show more output
# See Also:
#    man(3) foo
#    bar -- a related function in some way
function testFunc2ByAnotherName() { testFunc2 "$@"; }
function testFunc2() {
	:
}
