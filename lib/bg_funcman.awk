@include "bg_core.awk"
BEGIN {
	escapedTerms["\\\\"]="\\e"
	escapedTerms["\\\\efB"]="\\fB"
	escapedTerms["\\\\efR"]="\\fR"
	escapedOrder[1]="\\\\"
	escapedOrder[2]="\\\\efB"
	escapedOrder[3]="\\\\efR"
	escapedCount=3

	if (renderFlag)
		verbosity--

	# each array is key'd on the manpage name and the value is the string for that manpage
	arrayCreate(nameMap)             # nameMap[<name>]=<name>
	arrayCreate(manSectionMap)       # 1,2,3,etc...
	arrayCreate(docTypeMap)          # a string which coresponds to the filename extension of the template to use
	arrayCreate(shortDescriptionMap) # the one line description for this page
	arrayCreate(synopsisMap)         # synopsis section shows how to use/invoke the thing that the page is about
	arrayCreate(descriptionMap)      # main body of the page which comes mostly from formatting a comment block
	arrayCreate(aliasSectionMap)     # functions can have aliases which are other names to invoke it as
	arrayCreate(bodyMap)             # the code associated with this page. The function body for a function or global code for library
	arrayCreate(srcFileMap)          # filename that generated the page (maybe relative or absolute -- what ever was used on cmd line of awk)
	arrayCreate(srcPathMap)          # path part of filename
	arrayCreate(srcBaseMap)          # name.ext part of filename
	arrayCreate(lineMap)             # line number in filename where the function (or other object) was found

	# global variables
	gbl_manpageName=""       # the name of the manpage if one gets created from the current file section being scanned
	gbl_docType=""           # the type of the manpage which is the suffix of the template used to create the manpage
	gbl_refLineNumber=""     # the line number of where the target object is defined
	gbl_stateMachine=0       # state of the state machine
	gbl_comCount=0           # the number of comment lines collected in the current section

	arrayCreate(templateFindOptions)
	templateFindOptions["pkg"]="bg-dev"
}


# This assembles data that is collected over multiple lines.  Typically attribMap is a man page
# section and we add lines to that section as we find them. It also does some normalization.
function appendAttr(attribMap, recordName, data, sep            ,i) {
#if (recordName == "awkData_lookup") bgtraceVars2(2, "recordName", recordName" "sep" "data)
	maxlineLen=300
	if (length(data) > maxlineLen)
		data=substr(data, 0, (maxlineLen-4))"..."
	for (i=1; i<=escapedCount; i++) {
		gsub(escapedOrder[i],escapedTerms[escapedOrder[i]],data)
	}
	attribMap[recordName]=sprintf("%s%s%s", attribMap[recordName], ((sep)?sep:"\n"), data)
}

# wrapper over appendAttr that does some formatting specific to the synopsis section
function addSynopsisLine(pageName, line) {
	# remove the leading "usage: "
	sub("^(# )?usage:[[:space:]]*","",line); $0=line
	# add bold formatting to the function/command name
	if ($1 == pageName || $1 == srcBase)
		sub($1,"\\fB"$1"\\fR", line);
	if ($1 ~ "obj[.]") {
		line="\\fB"line
		sub(" ","\\fR ", line);
	}
	appendAttr(synopsisMap, pageName, " "line)
}

# The comments[i] map is constantly collected as the file is scanned. Periodically the state machine decides that a manpage should
# be created and the comments collecte over that section of the file is formatted into the descriptionMap.
# Params:
#    <gbl_manpageName>  : the name of the manpage is the key for all the Maps that store info about each manpage
#    <comments>     : an array of comment lines from the source file being scanned
# Output:
#    synopsisMap[gbl_manpageName], descriptionMap[gbl_manpageName], all the *Map[gbl_manpageName] global variables that store the manpage records
function formatCommentSection(manPageName, comments)
{
	for (i=0; i<gbl_comCount; i++) {
		$0=comments[i]; line=$0
		sub("^#* ?","",line); $0=line

		# usage: ...
		if ($1=="usage:") {
			addSynopsisLine(manPageName, "")
			addSynopsisLine(manPageName, line)
			if (file_doFuncList && manPageName!=srcBase) {
				if (! file_libFuncListHeaderWritten) {
					file_libFuncListHeaderWritten="1"
					addSynopsisLine(srcBase, "# Function List")
				}
				addSynopsisLine(srcBase, line)
			}
			while (i<gbl_comCount && comments[i+1] ~ "^(#?[[:space:]]*"manPageName")|(^#?        [^[:space:]])") {
				$0=comments[++i]; line=$0
				sub("^#[ ]*","",line);
				addSynopsisLine(manPageName, line)

				if (file_doFuncList && manPageName!=srcBase) {
					addSynopsisLine(srcBase, line)
				}
			}

		# Options:
		} else if ($0~"^[Oo]ptions?:[[:space:]]*$") {
			appendAttr(descriptionMap, manPageName, ".SH OPTIONS")

		# Parameters:
		} else if ($0~"^[Pp]aram(eter)?s?:[[:space:]]*$") {
			appendAttr(descriptionMap, manPageName, ".SH PARAMETERS")

		# Return Values:
		} else if ($0~"^([Rr]eturn [Vv]alues?|[Ee]xit [Cc]odes?):[[:space:]]*$") {
			appendAttr(descriptionMap, manPageName, ".SH EXIT CODES")

		# .sh ....
		} else if ($1~"^[.][sS][hH][[:space:]][[:space:]]*$") {
			sub("^[^ ]* ","",line)
			appendAttr(descriptionMap, manPageName, ".SH "line)

		# <SectionTitle>:
		} else if ($0~"^[A-Z][a-zA-Z0-9 ]*:[ \t]*$") {
			appendAttr(descriptionMap, manPageName, ".SH "line)

		# .<DIRECTIVE> ...
		} else if ($1~"^[.]") {
			appendAttr(descriptionMap, manPageName, line)

		# first comment body line goes into the shortDescription and the page body text
		} else if (!shortDescriptionMap[manPageName]) {
			shortDescriptionMap[manPageName]=line
			if (line !~ /[.]$/)
				appendAttr(descriptionMap, manPageName, " "line)

		# all the other comment body lines that do not match a directive
		} else {
			appendAttr(descriptionMap, manPageName, " "line)
		}
	}
}


# We are always collecting the current run of global comments in comments[]. At the end of the block, restartStateMachine is called
# and if the state indicates that the block contributes to a manpage, this function is called to parse the block into the manpage
# components
# as the state machine collects data into the global vars, that data may or may not go into creating a manpage
# at the end of a section that creates a manpage (like the end of a function definition) this function is called
# to move the data into the map vars that store the manpage records
# Note that the LibraryDescription page is unique in that it only formats its comment block
function createManPageRecord(manPageName, docType, refLine                           ,manSection)
{
	if (verbosity>=2) print("###    Creating: "manPageName" docType="docType)
	if (!(docType in seenDocType)) {
		_INDESC=refLine
		seenDocType[docType] = templateFind("funcman."docType, templateFindOptions)
		if (!seenDocType[docType]) {
			warning("no system template installed for funcman."docType, 1)
		}
	}
	templateFileMap[manPageName] = seenDocType[docType]
	manSection=docType; gsub("^[.]|[^0-9].*$","", manSection)
	nameMap[manPageName]=manPageName
	manSectionMap[manPageName]=manSection
	docTypeMap[manPageName]=docType
	srcFileMap[manPageName]=srcFile
	srcPathMap[manPageName]=srcPath
	srcBaseMap[manPageName]=srcBase
	lineMap[manPageName]=refLine

	if (synopsisMap[manPageName] == "" && manSection~/^[37]/) {
		addSynopsisLine(manPageName, "#!/usr/bin/bash")
		addSynopsisLine(manPageName, "source /usr/lib/bg_core.sh")
		if (!( srcBase in commonIncludes)) addSynopsisLine(manPageName, "import "srcBaseMap[manPageName]" ;$L1;$L2")
	}
	if (gbl_comCount>0)
		formatCommentSection(manPageName, comments)
}


###############################################################################################################################
### Start of scanning algorithm
# The input is multiple source files.  FNR==1 is the first line of each new file. Each file creates a man(7) or man(1) based on its
# filename pattern.
# We maintain a state machine which represents the context of the current line
#   gbl_stateMachine == 0 : global code or whitespace. scanning for a global directive, comment block start, or a function declaration
#   gbl_stateMachine == 1 : in a global comment block which might be a man page description or might not be.
#           reset to 0: an unrecognized line (which is typically whitespace but could be a code line that is not a function declaration)
#   gbl_stateMachine == 2 : in function declaration which may be a aliases (one line function declation and body) or the start of a function body
#           reset to 0: an unrecognized line (which is typically whitespace but could be a code line that is not a function declaration)
#   gbl_stateMachine == 3 : in function body
#           reset to 0: a '}' at the start of the line.
# Each time the state machine resets, if gbl_docType has been set, a manpage record will be created. If gbl_manpageName has been set but
# not gbl_docType, the collected comment block is formatted into the existing gbl_manpageName record (which is typically the lib or cmd page)
#   <docType> : represents one of the supported types of manpage and identifies the template to create the manpage
#              "<manSection>[.<type>]" : Example: 3.bashFunction is the manpage in section 3 for a bash function.




# this is called when the current line can not be a part of the previous block anymore so we create the manpage record if the
# gbl_docType is set and then reset the gbl_stateMachine to the beginning
function restartStateMachine()
{
	if (gbl_stateMachine==0) return

	# a section that is a complete manpage will set gbl_docType (and gbl_manpageName) (functions and # MAN(?) sections)
	# a comment block that adds to an existing manpage will set gbl_manpageName but not gbl_docType (# Library, # Command)
	if (gbl_docType) {
		createManPageRecord(gbl_manpageName, gbl_docType, gbl_refLineNumber)
	} else if (gbl_manpageName) {
		if (verbosity>=2) print("###    Adding comment section to page="gbl_manpageName)
		formatCommentSection(gbl_manpageName, comments)
	}

	gbl_manpageName=""
	gbl_docType=""
	gbl_refLineNumber=""
	gbl_stateMachine=0
	gbl_comCount=0
}

BEGIN {
	split(commonIncludesStr, commonIncludesTmp)
	for (i in commonIncludesTmp) commonIncludes[commonIncludesTmp[i]]=1
}

# start of a new file
FNR==1 {
	# finish up content from the last file if it was left hanging
	restartStateMachine()

	srcFile=FILENAME
	srcPath=srcFile; sub("/[^/]*$","",srcPath)
	srcBase=srcFile; sub("^.*/","",srcBase)

	file_autoFuncman=""
	file_doFuncList=""
	file_libFuncListHeaderWritten=""
	file_skip=""

	# if its a bash library file, create a man(7) page record for the library
	fileType=""
	if (srcBase ~ /[.](sh|PluginType|Config|Standards|Collect|RBACPermission)$/)
		fileType="lib"
	else if (srcBase !~ /[.]/)
		fileType="cmd"

	switch (fileType) {
	  case "lib":
		file_autoFuncman="1"
		file_doFuncList="1"
		createManPageRecord(srcBase, "7.bashLibrary", 1)
		addSynopsisLine(srcBase, "")
		break;
	  case "cmd":
		createManPageRecord(srcBase, "1.bashCmd", 1)
		break;
	}
}

# start each line assuming that the line is not recognized. Matching blocks will set it to recognized and at the end we will
# make unrecognized lines restart the state machine.
{lineRecognized=0; srcLine=$0}


### gbl_stateMachine==0 processing
#   these are stand alone, global directives and the global triggers that start potential manpage blocks


# import <libraryFilename> ;$L1;$L2
gbl_stateMachine==0 && /^import / {
	sep=""; if (libImports) sep=" "
	libImports=libImports""sep""$2
}

# NO_FUNC_MAN
# NO_FUNCMAN
# FUNCMAN_AUTOOFF
# A library can include this directive to exclude the remaining content from automatically creating function manpages
gbl_stateMachine==0 && /^#[[:space:]]*(NO_FUNC_MAN|NO_FUNCMAN|FUNCMAN_AUTOOFF)[[:space:]]*/ {file_autoFuncman=""}

# FUNCMAN
# FUNCMAN_AUTOON
# A library can include this directive to exclude the remaining content from automatically creating function manpages
gbl_stateMachine==0 && /^#[[:space:]]*(|FUNCMAN|FUNCMAN_AUTOON)[[:space:]]*$/ {file_autoFuncman="1"}

# FUNCMAN_NO_FUNCTION_LIST
gbl_stateMachine<=1 && /^#[[:space:]]*FUNCMAN_NO_FUNCTION_LIST/ {file_doFuncList=""; next}

# FUNCMAN_SKIP
gbl_stateMachine<=1 && /^#[[:space:]]*FUNCMAN_SKIP/ {file_skip="1"; next}


# Library [manpage]
# This directive provides the manpage description text for the library file that it is defined in.
# The manpage record is always created when a library file is encountered. This block optionally adds information to that manpage
gbl_stateMachine<=1 && gbl_comCount<=2 && /^#[[:space:]]*Library/ {
	gbl_manpageName=srcBase
	gbl_stateMachine=1
	# dont include this line in the comment body that forms the man page
	next
}


# Command [manpage] [<manPageName>]
# This directive provides the manpage description text for the command script file that it is defined in.
# The manpage record for the filename is always created when a command file is encountered. This block optionally adds information
# to that manpage when <manPageName> is not specified or is the filename. When <manPageName> is different, a new manpage is created
# for the sub cmd. This supports the git style where "git remote ..." has a manpage 'git-remote'
gbl_stateMachine<=1 && gbl_comCount<=2 && /^#[[:space:]]*Command/ {
	gbl_stateMachine=1
	gbl_manpageName=$0; gsub("^.*Command([[:space:]]*manpage[[:space:]]*|[[:space:]]*)?(:[[:space:]]*)?","", gbl_manpageName)
	if (!gbl_manpageName)
		gbl_manpageName=srcBase
	if (gbl_manpageName!=srcBase)
		gbl_docType="1.bashSubCmd"
	# dont include this line in the comment body that forms the man page
	next
}


# MAN(<docType>) <manPageName>
# This directive can be used to add the generation any arbitrary manpage to the source file.
# If the comment block that this directive appears in precedes a function declaration, this manpage name, section, and docType
# will override those that would have automatically been created for the function. If the function name matches a pattern that
# would normally have been ignored, this directive could be used to force a manpage to be created for it.
gbl_stateMachine<=1 && gbl_comCount<=2 && /^#[[:space:]]*[Mm][Aa][Nn][(][123456789].*[)][[:space:]]*[^[:space:]]+[[:space:]]*$/ {
	gbl_manpageName=$0; gsub("^.*[)][[:space:]]*|[[:space:]].*$","", gbl_manpageName)
	if (!gbl_manpageName) {
		warning("invalid manpage declaration in source. No name specified at src="srcFile"("refLine")", 1)
	} else {
		gbl_refLineNumber=FNR
		gbl_docType=$0; gsub("^.*[(][[:space:]]*|[[:space:]]*[)].*$","", gbl_docType)
		if (gbl_stateMachine<1) gbl_stateMachine=1
		# dont include this line in the comment body that forms the man page
		next
	}
}


### gbl_stateMachine<=1 processing
#   processing inside a comment block that might become a manpage

# global comments might be part of a manpage block. Note that only non-indented comments are matched.
# this block can trigger the start of a comment block or continue the collection in a block
gbl_stateMachine<=1 && /^#/ {
	comments[gbl_comCount++]=$0
	lineRecognized=1
	if (gbl_stateMachine<1) gbl_stateMachine=1
}

# determine if we should recognize a blank line as part of the block. if we set spaceThreshold greater than 0 it will allow
# that number of spaces to appear in the block. Otherwise, not recognizing the space will cause the current block to end.
# 2020-10 Note that this is disabled. Any empty line will disrupt a comment block (but not a function body which is a higher state)
gbl_stateMachine<=1 && /^$/ {spaceThreshold=0; consequtiveSpaceCount++; if (consequtiveSpaceCount<=spaceThreshold) lineRecognized=1}
gbl_stateMachine<=1 && /[^[:space:]]/ {consequtiveSpaceCount=0}


### gbl_stateMachine<=2 processing
#   processing function and alias declarations

# function alias line
# this matches the pattern we use to create an alias for a function. When we rename a function,  we create an alias
# with the previous name until we are sure that its no longer used (or users have been sufficiently warned)
# This line is between the function comment sections and the function definition of the read function.
#      e.g.    function aliasFnName() { targetFnName "$@"; }
gbl_stateMachine<=2 && /^function[[:space:]][a-zA-Z].*[{][[:space:]]+[^[:space:]]*[[:space:]]+"[$]@"[[:space:]]*;[[:space:]]+[}]/ {
	if (fileType=="lib") {
		aliasName=$2; sub("[(][)]$","",aliasName)
		target=$0; sub("^.*[{][ \t]*","",target); sub(" .*$","",target)
		aliasesMap[target]=aliasesMap[target] ((aliasesMap[target])?" ":"") aliasName
	}

	lineRecognized=1
	if (gbl_stateMachine<2) gbl_stateMachine=2

	# an alias line will also match a function declaration so skip futher processing
	next
}

# function declaration line
gbl_stateMachine<=2 && /^function[[:space:]]*[_a-zA-Z][^(]*[(][)]/ {
	functionName=$2; sub("[(][)]$","",functionName)

	# the name matches our policy, turn on man3 doctype if its not already on
	if (file_autoFuncman && ! file_skip && !gbl_docType && functionName !~ "^_") {
		gbl_manpageName=functionName
		gbl_docType="3.bashFunction"
		if (!gbl_refLineNumber) gbl_refLineNumber=FNR
	}
	file_skip=""

	lineRecognized=1

	# if its a declaration without a body, we move to state 3 to collect the body
	if (NF==2 || (NF==3 && $3 == "{")) {
		gbl_stateMachine=3

	# else its a one line function
	} else {
		if (gbl_manpageName) appendAttr(bodyMap, gbl_manpageName, " "$0)
		restartStateMachine()
	}
}


### gbl_stateMachine==3 processing
#   collect the function body

# collect the function body lines
gbl_stateMachine==3 {
	appendAttr(bodyMap, gbl_manpageName, " "$0)
	lineRecognized=1
}

# detect the end of a top level function body.
gbl_stateMachine==3 && /^[}]/ {
	restartStateMachine()
	next
}

# When we are testing, print diagnostic info to stdout
verbosity>=3 {printf("%3s %s: %s\n", NR, gbl_stateMachine, srcLine)}

# collect global code for the library 'body'
gbl_stateMachine==0 && srcLine!~/^[[:space:]]*#/ {
	if (srcLine!~/^[[:space:]]*$/ || bodyMap[srcBase] !~ /\n[[:space:]]*\n$/)
		appendAttr(bodyMap, srcBase, srcLine)
}

# reset the accumulated comments any time we hit a line that can not be part of the last manpage context. This is typically a
# blank line after a top level (not indented) comment block
!lineRecognized {
	restartStateMachine();
}

END {
	for (f in nameMap) {

		# build the context that the manpage template will be expanded within
		delete context
		context["filename"]=srcBaseMap[f]
		context["filenameFull"]=srcFileMap[f]
		context["filenamePath"]=srcPathMap[f]
		context["line"]=lineMap[f]
		context["shortDescription"]=((shortDescriptionMap[f]) ? shortDescriptionMap[f] : "bash function")
		context["description"]=descriptionMap[f]
		context["synopsis"]=synopsisMap[f]
		context["aliases"]=aliasesMap[f]
		context["body"]=bodyMap[f]

		# manSection can have a suffix like 3sh
		# manSectionNumber has the suffix removed and is used for the folder name of the output file
		manSectionNumber=manSectionMap[f]; sub("[^0-9]*$","", manSectionNumber)
		if (manSectionMap[f] ~ /^[37]$/)
			manSectionMap[f]=manSectionMap[f]"sh"
		context["manSection"]=manSectionMap[f]

		context["pageName"]=f
		switch (manSectionNumber) {
			case 1: context["cmdName"]=f;      break;
			case 3: context["functionName"]=f; break;
			case 7: context["libName"]=f;      break;
		}

		# if the manpage already exists, get the month and year from the existing file b/c we need the content to be identical if
		# it has not changed.
		# TODO: maintain a separate file that contains lines "<gbl_manpageName> <year> <month>" that is committed to git so that we
		#       dont rely on a continuous, uninterrupted generated manpage history to get the creation time date right
		existingManFile=outputFolder"/man"manSectionNumber"/"f"."manSectionMap[f]
		if ( (getline < existingManFile) > 0) {
			gsub("\"","")
			if ($4~/^(January|February|March|April|May|June|July|August|September|October|November|December)$/) context["month"]=$4
			if ($5~/^[23][0-9][0-9][0-9]$/) context["year"]=$5
		}
		close(existingManFile)

		if (aliasesMap[f]) {
			appendAttr(context, "aliasSection", ".SH Aliases")
			appendAttr(context, "aliasSection", "This function can also be called by other names. This is usually a temporary situation while changing a function name.")
			split(aliasesMap[f], functionNames)
			for (i in functionNames) {
				appendAttr(context, "aliasSection", " "functionNames[i])
			}
		}

		split(f" "aliasesMap[f], functionNames)
		for (i in functionNames) {
			pagename=functionNames[i]
			if (renderFlag) {
				if (renderFlag=="all" || renderFlag==pagename) {
					outFile="-"
					if (tmpFolder)
						outFile=tmpFolder"/"pagename
					else {
						printf("\n\n\n###########################################################################################\n")
						printf("### MANPAGE %s\n", pagename)
					}
					expandTemplate(templateFileMap[f], context, outFile)
				}
			} else if (tmpFolder) {
				outfolder=tmpFolder"/man"manSectionNumber""
				if (!fsExists(outfolder))
					fsTouch(outfolder"/")
				outFile=outfolder"/"pagename"."manSectionMap[f]
				expandTemplate(templateFileMap[f], context, outFile)
			}
		}
		if (verbosity==1) printf("manpage %-18s %s\n", docTypeMap[f], f)
		if (verbosity>=4) printfVars("context")
	}
}
