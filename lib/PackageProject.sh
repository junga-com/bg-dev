import Project.sh  ;$L1;$L2

DeclareClass PackageProject Project

function PackageProject::__construct()
{
	# pkg projects store the version in the doc/changelog file.
	if [ -f "${this[absPath]}"/doc/changelog ]; then
		this[version]="$(gawk 'NR==1 {print gensub(/^[^(]*[(]|[)].*$/,"","g",$0); exit}' "${this[absPath]}"/doc/changelog )"
		this[version]="${this[version]#v}"
	else
		# typically this default wont kick in because the template for new projects has a ./doc/changelog file with the starting version
		this[version]="0.0.0"
	fi
}

# usage: $proj.make <pkgType>
function PackageProject::makePackage()
{
	$this.cdToRoot
	local runLintianFlag makeChangesFlag
	while [ $# -gt 0 ]; do case $1 in
		--lintian) runLintianFlag=1 ;;
		--changes) makeChangesFlag=1 ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done
	local pkgType="${1:-deb}"
	local pkgName="${this[packageName]}"

	# scan for assets to make sure the list of assets is up-to-date
	static::PackageAsset::updateProjectManifest

	# make sure that the funcman assets are up-to-date. funcman manintains the manifest file if any manpages are added or removed.
	funcman_runBatch -q

	this[version]="$(dpkg-parsechangelog -ldoc/changelog | sed -n -e 's/^Version:[ \t]*//p')"

 	case $pkgType in
		deb|both)
			echo "making deb package..."
			assertFileExists pkgControl/debControl "pkgControl/debControl is required to build a deb package. See 'control' file in debian policy documentation"

			local stagingFolder=".bglocal/pkgStaging-deb"

			### Install the package's assets into the stagingFolder
			static::PackageAsset::installAssets --no-update "deb" "$stagingFolder"

			### Make the DEBIAN pkg control folder in the stagingFolder from the shared pkgControl folder
			mkdir -p $stagingFolder/DEBIAN
			if [ -e pkgControl/lintianOverrides ]; then
				mkdir -p $stagingFolder/usr/share/lintian/overrides/
				mv pkgControl/lintianOverrides $stagingFolder/usr/share/lintian/overrides/${this[packageName]}
				chmod 0644 $stagingFolder/usr/share/lintian/overrides/${this[packageName]}
			fi
			for i in preinst postinst prerm postrm; do
				if [ -f "pkgControl/$i" ]; then
					cp "pkgControl/$i" $stagingFolder/DEBIAN/
					chmod 775 $stagingFolder/DEBIAN/$i
				fi
			done
			chmod -R g-w $stagingFolder/

			### Create the binary control file for the pkg from the source control file
			dpkg-gencontrol -cpkgControl/debControl -ldoc/changelog -fpkgControl/files -P$stagingFolder/

			### Make the deb file from the staging folder
			fakeroot dpkg-deb -Zgzip --build $stagingFolder/ ${this[packageName]}_${this[version]}_all.deb

			## run lintian to check for issues
			if [ "$runLintianFlag" ]; then
				printf "${csiBold}lintian:${csiNorm} %s\n" "${this[packageName]}_${this[version]}_all.deb"
				if ! lintian ${this[packageName]}_${this[version]}_all.deb; then
					echo "stopping because package contains lintian issues."
					return 1
				fi
			fi

			### Create the .changes file which will be used to upload the package to repositories
			if [ "$makeChangesFlag" ]; then
				local pubishUser="$(gawk '/^Maintainer:/ {gsub("^.*<|>.*$",""); print}' pkgControl/debControl)"
				dpkg-genchanges -b  -cpkgControl/debControl -ldoc/changelog -fpkgControl/files -u. -O${this[packageName]}_${this[version]}_all.changes.unsigned
				if gpg -k "<$pubishUser>" &>/dev/null; then
					rm -f ${this[packageName]}_${this[version]}_all.changes
					if gpg --use-agent --clearsign --batch -u "<$pubishUser>" -o ${this[packageName]}_${this[version]}_all.changes -- ${this[packageName]}_${this[version]}_all.changes.unsigned; then
						printf "${csiBold}gpg :${csiNorm} signed changes file with %s's key\n" "$pubishUser"
						rm ${this[packageName]}_${this[version]}_all.changes.unsigned
					else
						printf "${csiBold}gpg :${csiRed} FAILED to sign changes file with %s's key. changes file is unsigned${csiNorm}\n" "$pubishUser"
						mv ${this[packageName]}_${this[version]}_all.changes.unsigned ${this[packageName]}_${this[version]}_all.changes
					fi
				else
					echo "The maintainer user specified in the pkgControl/debControl file, '$pubishUser' does not have a gpg key to sign the changes file."
					echo "The .changes file will not be signed"
					mv ${this[packageName]}_${this[version]}_all.changes.unsigned ${this[packageName]}_${this[version]}_all.changes
				fi
				chmod 644 ${this[packageName]}_${this[version]}_all.changes
			fi

			# report finish
			echo "built package '${this[packageName]}_${this[version]}_all.deb'"
			;;&

		rpm|both)
			echo "making rpm package..."
			assertFileExists pkgControl/rpmControl "pkgControl/rpmControl is required to build a deb package. See 'control' file in debian policy documentation"
			local stagingFolder=".bglocal/rpmbuilding/pkgStaging-rpm"
			mkdir -p ".bglocal/rpmbuilding"

			static::PackageAsset::installAssets --no-update "rpm" "$stagingFolder"
			chmod -R g-w $stagingFolder/

			rpmbuild --define "_topdir .bglocal/rpmbuilding/rpmbuild"  --buildroot "${PWD}/$stagingFolder"   -bb pkgControl/rpmControl
			mv .bglocal/rpmbuilding/rpmbuild/RPMS/noarch/*.rpm .
			;;&
	esac
}

function PackageProject::setVersion()
{
	local newVersion="${1#v}"

	if [ "${this[lastRelease]}" ] && ! versionGt "$newVersion" "${this[lastRelease]}"; then
		assertError -v project:this[name] -v lastRelease:this[lastRelease] -v specifiedVersion:newVersionSpec "The specified version number is not greater than the last published release version number"
	fi

	local version="$newVersion"
	local fullUsername="$(git config user.name)"
	local userEmail="$(git config user.email)"
	local packageName="${this[packageName]}"

	# make sure that the doc/ folder exists
	fsTouch -d "${this[absPath]}/doc/"

	import bg_template.sh ;$L1;$L2

	if [ "${this[version]}" == "${this[lastRelease]}" ] || [ ! -s "${this[absPath]}/doc/changelog" ]; then
		# add a new entry
		templateExpand changelogEntry > "${this[absPath]}/doc/changelog.new"
		[ -f "${this[absPath]}/doc/changelog" ] && cat "${this[absPath]}/doc/changelog" >> "${this[absPath]}/doc/changelog.new"
		mv "${this[absPath]}/doc/changelog.new" "${this[absPath]}/doc/changelog"
	else
		# change the version of the last entry in the file b/c that entry has not yet been published
		bgawk -i \
			-v oldVersion="${this[version]#v}" \
			-v newVersion="$newVersion" '

			!found && /^[[:space:]]*$/ {print $0; next}
			!found {
				found=1
				sub("[(]"oldVersion"[)]", "("newVersion")")
			}
		' "${this[absPath]}/doc/changelog"
	fi

	this[version]="$newVersion"
}



function PackageProject::publishCommit()
{
	echo "PackageProject::publishCommit not yet implemented"
}
