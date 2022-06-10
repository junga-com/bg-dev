

# usage: gitProj::loadAttributes <retAttribArrayVar> <gitFolder>
# This is the guts behind the gitStatus and gitInfo functions. It collects a number of high level attributes
# This should only initialize attributes that are quick to get and should not do any significant work.
# General Attributes:
#   displayName   : The simple name of the repo (no .git, no path)
#   gitFolder     : the path to the worktree
#   gitFolderOpt  : a string that contains git options that will cause git commands to operate on this project
#                   even if the PWD is not in the project
#   gitRepo       : the path to the hidden repo folder
#   remoteHost    : the actual host that will be used to pull changes from. This is useful to check reachability
#                   before git operations that might hang for a long time when the host is not available
#                   TODO: this should be split into branchHostPull and branchHostPush
#   changesStatus : an overall short description summarizing the state of the local repo
#                   [changes:<n>][behind:<m>][ahead:<o>][unique:<p>]    -- when the corresponding value is 0, the term is left out
#   syncState     : This is meant to guide the user to understand if the current branch is backed up
#                   dirtyFolder -- the worktree contains work that would be lost if not committed
#                   newCommits  -- the local repo contains commits that would be lost if not pushed somewhere
#                   syncd       -- all work in this branch is represented on the remote server
#                   TODO: we need to indicate if there are other branches that are not backed up to an upstream git server. if there is at least one other branch with changes append an '*'
#   canAmend      : True if the HEAD commit is not reachable by any other branch
#   dirtyIndicator: three characters that indicate 1) is the working tree dirty, 2) local commits vs remote commits,
#                   and 3) current content vs last release
#
# Branch Attributes:
#   branchName    : name of the current branch that the local worktree is on
#   branchType    : what type of branch is it
#                   local    -- only a local branch. there is no coresponding remote tracking branch (yet)
#                   tracking -- there is a local and remote branch and the local is configured to track the remote
#                   severed  -- there are both local and remote but the tracking config is missing
#                   detached -- no branch is set. a specific commit, or tag, was checked out and there and there is no local branch
#   branchRemote  : The remote (i.e. origin) that the current branch is tracking. "origin" is the default
#   branchMerge   : the value of the branch.$branchName.merge setting
#   branchTracking: the remote branch that the local branch is tracking. Typically its origin/$branchName
#   branchURL     : The logical (master) URL of the branchRemote. This might not be the URL used for operations
#                   but it is the identifier of the place where the branch is tracking
#   branchedFrom  : the branch that this branch was branched from. (recorded in the .bg{,local}/branches/ folder)
#                    if the branchType is 'local' this will be the branch that it was branched from.
#
# Repo State Attributes:
#   commitsBehind : how many commits are in the remote tracking branch that are not yet reflected in this local branch
#   commitsAhead  : how many commits are in the local branch that are not yet reflected in the remote branch
#                   note that for merges, this number counts all the commits merged. So performing a merge may bump
#                   this number more than one which I find unintuitive. If the merge is FF, this number could
#                   be non-zero even though there is no unique content in the the local branch
#   commitsAheadStr: oneline per commit description of the commitsAhead commits
#
# Worktree State Attributes:
#   changes       : text containing an output similar to 'git status -s'
#   changesCount  : a count of changes present in the working tree and index that would be in the next commit
#
# See Also:
#   gitInfo()
#   gitStatus()
function gitProj::loadAttributes()
{
	#varExists this || local -n this="$1"
	local gitFolder="${2:-${this[absPath]:-${this[path]}}}"

	[ ! -e "$gitFolder/.git" ] && assertError -v gitFolder "gitFolder is not a git working tree folder"

	local gitFolderOpt="-C $gitFolder";
	local gitRepo="$gitFolder/.git"; [ -f "$gitFolder/.git" ] && gitRepo="$(realpath --relative-to="$PWD" "$gitFolder/.git")"

	# save the identity information into the attribute array

	this[gitFolder]="$gitFolder"
	this[gitFolderOpt]="$gitFolderOpt"
	this[gitRepo]="$gitRepo"


	### get branch information

	this[branchName]="$(git $gitFolderOpt symbolic-ref --short HEAD 2>/dev/null)"
	this[branchName]="${this[branchName]:-HEAD}"

	# get the upstream branch info. If its not tracking, there is no real remote for this branch but in support of ondemand local
	# branches we fill in the branchRemote and branchTracking with the names it would have if we push the branch
	this[branchRemote]="$(git $gitFolderOpt config --get branch.${this[branchName]}.remote)"
	this[branchMerge]="$( git $gitFolderOpt config --get branch.${this[branchName]}.merge)"
	this[branchTracking]="${this[branchRemote]:-origin}/${this[branchName]}"
	this[branchURL]="$(git $gitFolderOpt config --get remote.${this[branchRemote]:-origin}.url)"
	this[branchURL]="${this[branchURL]:-${this[branchRemote]:-origin}}"

	# # the branchedFrom is either the tracking remote or the place that we branched from if there is no tracking branch
	# gitGetBranchedFrom -R this[branchedFrom] "$gitFolder" "${this[branchName]}"

	# determine the type of the branch
	if [ "${this[branchName]}" == "HEAD" ]; then
		this[branchType]="detached"
	elif [ "${this[branchMerge]}" ] && [ "$(git $gitFolderOpt cat-file -t "${this[branchTracking]}" 2>/dev/null)" ]; then
		this[branchType]="tracking"
	elif [ "$(git $gitFolderOpt cat-file -t "${this[branchTracking]}" 2>/dev/null)" ]; then
		this[branchType]="severed"
	else
		this[branchType]="local"
	fi


	### get the commitited repo state (commitsAhead and commitsBehind)

	# iterate the other branches that are not checked out to see if any are dirty
	$this.branches=new Map
	local -n branchesMap; GetOID ${this[branches]} branchesMap || assertError
	local branchIsHead branchName remoteBranch changes branchType
	while read -r branchIsHead branchName remoteBranch changes; do
		if [ "$branchIsHead" == "n" ]; then
			[ "$remoteBranch" == "--" ] && branchType="local" || branchType="tracking"
			if [ "$branchType" == "local" ]; then
				local aheadCount="$(git rev-list "$branchName" --not --exclude="$branchName" --remotes | wc -l)"
				[ ${aheadCount:-0} -gt 0 ] && changes="[ahead:$aheadCount]" || changes="[syncd]"
			else
				changes="${changes:-[syncd]}"
			fi
			branchesMap[$branchName]="$branchType ${changes}"
			[[ ! "$changes" =~ sync ]] && this[dirtyBranches]+="$branchName "
		fi
		#printfVars -1 branchIsHead branchName remoteBranch changes
	done < <(git for-each-ref --format='%(if)%(HEAD)%(then)y%(else)n%(end)  %(refname:strip=2) %(if)%(upstream)%(then)%(upstream:strip=2)%(else)--%(end)  %(upstream:track)' -- 'refs/heads')

	if [ "${this[branchType]}" == "tracking" ] || [ "${this[branchType]}" == "severed" ]; then
		this[commitsBehind]=$(   git $gitFolderOpt rev-list ${this[branchName]}..${this[branchTracking]} | wc -l)
		this[commitsAhead]=$(    git $gitFolderOpt rev-list ${this[branchTracking]}..${this[branchName]} | wc -l)
		this[commitsAheadStr]="$(git $gitFolderOpt log --oneline ${this[branchTracking]}..${this[branchName]} -- 2>/dev/null)"
		[ ${this[commitsAhead]:-0} -gt 0 ] && this[ffPush]="$(git $gitFolderOpt branch -r --contains "${this[branchName]}" | awk 'NR==1{exit;} END{if (NR>0) print "ffPush"}')"
		# TODO: after merging another branch into master that is all (or partial) FF because no changes were made to master since the other branch started,
		#        commitsAhead reports all those new commits which is missleading because we probably want to see that there are 0 or 1 new commits as a results
		#        of the merge.
		#        This is what commitsAheadUnique was getting at but that was also misleading. I think that commitsAhead should really be commitsUnsaved (new, not pushed to origin)
		#        and we should also indicated when a FF push is needed. I.E. after a FF merge to master, there are no new commits, but the state that needs to be pushed is just
		#        to update the origin/master to the local master.
	elif [ "${this[branchType]}" == "local" ]; then
		# local branches do not yet have a origin/<branchName> so report about commits that are not reachable from other refs

		# we are not tracking anything so we can not be behind anything
		this[commitsBehind]=0

		# this blocks uses 'git branch -r --contains $commitID' to walk back and count how many
		# commits are not reachable from any remote branch. These are commits that would be lost if
		# we lost the local repo
		# TODO: refactor this to use (aheadCount="$(git rev-list "$branchName" --not --exclude="$branchName" --remotes | wc -l)") or (git for-each-ref --contains|--no-merge|<something)>
		this[commitsAhead]=0
		local commitID="$(git $gitFolderOpt rev-parse "${this[branchName]}" 2>/dev/null)"
		while git $gitFolderOpt rev-parse --verify -q "$commitID" &>/dev/null && [ "$(git $gitFolderOpt branch -r --contains "$commitID" 2>/dev/null | awk 'NR==1{exit;} END{if (NR==0) print "dirty"}')" ]; do
			((this[commitsAhead]++))
			this[commitsAheadStr]+="${this[commitsAheadStr]:+$'\n'}$(git $gitFolderOpt log --oneline -1 ${commitID} 2>/dev/null)"
			commitID="$(git $gitFolderOpt rev-parse "${commitID}~1" 2>/dev/null)" || break
		done
	else
		# for detached branches (i.e. no branch) there is no concept of being ahead or behind
		this[commitsBehind]=0
		this[commitsAhead]=0
	fi

	# can the HEAD be reached by any other ref beside our branch? If this command returns only our this[branchName] (and no other lines), we could ammend it if we want to.
	this[canAmend]="$(git $gitFolderOpt branch -a --contains HEAD 2>/dev/null | awk 'NR==2{exit;} END{if (NR==1 && $2=="'"${this[branchName]}"'") print "yes"}')"


	### get the worktree change status

	# TODO: consider using 'git diff --name-only  HEAD' instead of 'git $gitFolderOpt status -uall --porcelain --ignore-submodules=dirty'. Its faster but does not including new files and does not distinguish between staged and unstaged changes but we don't really care about that anyway
	this[changes]="$(git $gitFolderOpt status -uall --porcelain --ignore-submodules=dirty | head -n200)"
	this[changesCount]="$(echo "${this[changes]}" | grep -v "^$" | wc -l )"


	### overall current branch info

	[[ "${this[changesCount]}" > 0 ]] \
		&& this[changesStatus]="changes:${this[changesCount]}"
	[[ ${this[commitsBehind]} > 0 ]]  \
		&& stringJoin -a -e -d"," -R this[changesStatus] "behind:${this[commitsBehind]}"
	[[ ${this[commitsAhead]}  > 0 ]] \
		&& stringJoin -a -e -d"," -R this[changesStatus] "ahead:${this[commitsAhead]}"

	# this case statement matches the most specific case first. When you see a * in one of the three fields
	# it means that its something other that the specific (0) value that preceeeds it
	case ${this[changesCount]}:${this[commitsAhead]}:${this[commitsBehind]}:${this[dirtyBranches]} in
		0:0:0:)    this[syncState]="syncd" ;;
		0:0:0:*)   this[syncState]="dirtyBranches" ;;
		0:0:*:)    this[syncState]="behind" ;;
		0:*:*:)    this[syncState]="newCommits"; [ "${this[ffPush]}" ] && this[syncState]="ffPush" ;;
		*:*:*:)    this[syncState]="dirtyFolder" ;;
	esac


	#git for-each-ref --format='%(refname) %(upstream)' -- 'refs/heads'

	# get the remote host and repoName. Note that the actual URL may not be the one in the config because of redirection config
	# that is why we run it through the 'ls-remote --get-url' command. We prefer the values in this order
	this[remoteHost]="$(git $gitFolderOpt ls-remote --get-url "${this[branchURL]}")"
	[ "${this[remoteHost]}" == "origin" ] && this[remoteHost]="" # if ls-remote did not translate 'origin' to a url, it does not exist
	local repoName
	parseURL -p"git://" "${this[remoteHost]}" "" "" "" this[remoteHost] "" repoName

	this[displayName]="$(getIniParam $gitFolder/.bg/bg-git.conf . name 2>/dev/null)"
	this[displayName]="${this[displayName]:-"${repoName:-${gitFolder}}"}"
	this[displayName]="${this[displayName]##*/}"
	this[displayName]="${this[displayName]%.git}"

	# get the last tag that looks like a version number if it exists
	# If a tag is found, it will be the latest release. If not it means that this proj has never been released
	# Note that the project might have a version stored that is already incremented for the next release.
	this[lastRelease]="$(git ${this[gitFolderOpt]} tag -l --sort="-version:refname" "v[0-9]*" | head -n1)"

	# releasePending is boolean that is true only if there has been a release and no changes in this folder since the last release
	# if (there has never been a published version)
	#    or (HEAD is past the last published version)
	#    or (the workTree is dirty)
	this[releasePending]=""
	if [ ! "${this[lastRelease]}" ] \
		|| [ "$(git ${this[gitFolderOpt]} rev-list "^${this[lastRelease]}" HEAD)" ] \
		|| [ ${this[changesCount]:-0} -gt 0 ]; then
		this[releasePending]="1"
	fi


	local dirtyIndicator
	# working tree vs checked out commit
	if [ ${this[changesCount]:-0} -gt 0 ]; then
		dirtyIndicator="-";
	else
		dirtyIndicator=" ";
	fi
	# local commits vs remote commits.
	if [ $((${this[commitsAhead]})) -gt 0 ] && [ $((${this[commitsBehind]})) -gt 0 ]; then
		dirtyIndicator+=":";
	elif [ $((${this[commitsAhead]})) -gt 0 ]; then
		dirtyIndicator+="-";
	elif [ $((${this[commitsBehind]})) -gt 0 ]; then
		dirtyIndicator+=".";
	else
		dirtyIndicator+=" ";
	fi
	# current content vs last release
	if [ "${this[releasePending]}" ]; then
		dirtyIndicator+="+"
	else
		dirtyIndicator+=" "
	fi
	this[dirtyIndicator]="$dirtyIndicator"
}
