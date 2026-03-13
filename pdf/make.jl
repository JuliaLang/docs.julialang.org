using Base64
import Dates

const BUILDROOT      = get(ENV, "BUILDROOT", pwd())
const JULIA_SOURCE   = get(ENV, "JULIA_SOURCE", "$(BUILDROOT)/julia")
const JULIA_DOCS     = get(ENV, "JULIA_DOCS", "$(BUILDROOT)/docs.julialang.org")
const JULIA_DOCS_TMP = get(ENV, "JULIA_DOCS_TMP", "$(BUILDROOT)/tmp")

const MIN_PDF_SIZE = 1_000_000 # 1 MB minimum for a valid Julia manual PDF

# download and extract binary for a given version, return path to executable
function download_release(v::VersionNumber)
    x, y = v.major, v.minor
    julia_exec = cd(BUILDROOT) do
        julia = "julia-$(v)-linux-x86_64"
        tarball = "$(julia).tar.gz"
        sha256 = "julia-$(v).sha256"
        url = "https://julialang-s3.julialang.org/bin/linux/x64/$(x).$(y)/$(tarball)"
        sha_url = "https://julialang-s3.julialang.org/bin/checksums/$(sha256)"
        @info "Downloading release tarball." url sha_url
        run(`curl --retry 5 --retry-delay 10 -fvo $(tarball) -L $(url)`)
        run(`curl --retry 5 --retry-delay 10 -fvo $(sha256) -L $(sha_url)`)
        try
            run(pipeline(`grep $(tarball) $(sha256)`, `sha256sum -c`))
        catch e
            @info "Contents of SHA256 file:\n$(read(sha256, String))"
            rethrow(e)
        end
        mkpath(julia)
        run(`tar -xzf $(tarball) -C $(julia) --strip-components 1`)
        return abspath(julia, "bin", "julia")
    end
    return julia_exec
end
# download and extract nightly binary, return path to executable and commit
function download_nightly()
    julia_exec, commit = cd(BUILDROOT) do
        julia = "julia-latest-linux64"
        tarball = "$(julia).tar.gz"
        url = "https://julialangnightlies-s3.julialang.org/bin/linux/x64/$(tarball)"
        @info "Downloading nightly tarball." url
        run(`curl --retry 5 --retry-delay 10 -fvo $(tarball) -L $url`)
        # find the commit from the extracted folder
        folder = first(readlines(`tar -tf $(tarball)`))
        _, commit = split(folder, '-'); commit = chop(commit)
        mkpath(julia)
        run(`tar -xzf $(tarball) -C $(julia) --strip-components 1`)
        return abspath(julia, "bin", "julia"), commit
    end
    return julia_exec, commit
end

function makedocs(julia_exec)
    # Override build_datarootdir so the Makefile's stdlibdir points to the downloaded binary's stdlib.
    stdlibdir = readchomp(`$(julia_exec) -e 'print(Sys.STDLIB)'`)
    datarootdir = abspath(joinpath(stdlibdir, "..", "..", ".."))
    @sync begin
        builder = @async begin
            withenv("DOCUMENTER_KEY" => nothing, # skips deploydocs with the BuildBotConfig (see doc/make.jl)
                    "BUILDROOT" => nothing) do
                run(`make -C $(JULIA_SOURCE)/doc pdf JULIA_EXECUTABLE=$(julia_exec) build_datarootdir=$(datarootdir)`)
            end
        end
        @async begin
            while !istaskdone(builder)
                sleep(60)
                @info "[$(Dates.format(Dates.now(), raw"yyyy-mm-dd\THH:MM:SS"))] building pdf ..."
            end
        end
    end
end

function validate_pdf(path)
    if !isfile(path)
        error("PDF not found: $path")
    end
    size = filesize(path)
    if size < MIN_PDF_SIZE
        error("PDF too small ($(size) bytes): $path — likely corrupted or incomplete")
    end
    header = open(io -> read(io, 5), path)
    if header != UInt8['%', 'P', 'D', 'F', '-']
        error("Not a valid PDF (bad header): $path")
    end
    @info "PDF validated." path size_mb=round(size / 1_000_000; digits=1)
end

function copydocs(file)
    isdir(JULIA_DOCS_TMP) || mkpath(JULIA_DOCS_TMP)
    output = "$(JULIA_SOURCE)/doc/_build/pdf/en"
    destination = "$(JULIA_DOCS_TMP)/$(file)"
    for f in readdir(output)
        if startswith(f, "TheJuliaLanguage") && endswith(f, ".pdf")
            cp("$(output)/$(f)", destination; force=true)
            validate_pdf(destination)
            @info "finished, output file copied to $(destination)."
            return
        end
    end
    error("No PDF found in $(output)")
end

function build_release_pdf(v::VersionNumber; skip_existing::Bool=true, checkout::Bool=true)
    @info "building PDF for Julia v$(v)."

    file = "julia-$(v).pdf"

    # early return if file exists
    if skip_existing && isfile("$(JULIA_DOCS)/$(file)")
        @info "PDF for Julia v$(v) already exists, skipping."
        return
    end

    # download julia binary
    julia_exec = download_release(v)

    # checkout relevant tag and clean repo (skip if already at the right ref via shallow clone)
    if checkout
        run(`git -C $(JULIA_SOURCE) checkout v$(v)`)
        run(`git -C $(JULIA_SOURCE) clean -fdx`)
    end

    # invoke makedocs
    makedocs(julia_exec)

    # copy built PDF to JULIA_DOCS_TMP
    copydocs(file)
end

function build_nightly_pdf()
    julia_exec, commit = download_nightly()
    # output is "julia version 1.1.0-DEV"
    _, _, v = split(readchomp(`$(julia_exec) --version`))
    @info "commit determined to $(commit) and version determined to $(v)."

    # fetch and checkout the nightly commit (shallow clone may not have it)
    run(`git -C $(JULIA_SOURCE) fetch --depth 1 origin $(commit)`)
    run(`git -C $(JULIA_SOURCE) checkout $(commit)`)
    run(`git -C $(JULIA_SOURCE) clean -fdx`)

    # invoke makedocs
    makedocs(julia_exec)

    # copy the built PDF to JULIA_DOCS
    copydocs("julia-$(v).pdf")
end

# find all tags in the julia repo
function collect_versions()
    str = read(`git -C $(JULIA_SOURCE) ls-remote --tags origin`, String)
    versions = VersionNumber[]
    for line in eachline(IOBuffer(str))
        # lines are in the form 'COMMITSHA\trefs/tags/TAG'
        _, ref = split(line, '\t')
        _, _, tag = split(ref, '/')
        if occursin(r"^v\d+\.\d+\.\d+(?:-(:?alpha|beta|rc)\d+)?$", tag)
            # the version regex is not as general as Base.VERSION_REGEX -- we only build
            # release and pre-release versions (alpha, beta, rc) but exclude tags with
            # build information or non-standard pre-release labels.
            v = VersionNumber(tag)
            # pdf doc only possible for 1.1.0 and above
            v >= v"1.1.0" || continue
            # only build pre-releases for 1.10+
            (v.major, v.minor) < (1, 10) && !isempty(v.prerelease) && continue
            push!(versions, v)
        end
    end
    return versions
end

# similar to Documenter.deploydocs
function commit()
    if get(ENV, "GITHUB_EVENT_NAME", nothing) == "pull_request"
        @info "skipping commit from pull requests."
        return
    end
    if !isdir(JULIA_DOCS_TMP) || isempty(filter(f -> endswith(f, ".pdf"), readdir(JULIA_DOCS_TMP)))
        @info "No new PDFs found, skipping commit."
        return
    end
    @info "committing built PDF files."

    # Make sure the repo is up to date
    run(`git fetch origin`)
    run(`git reset --hard origin/assets`)

    # Copy file from JULIA_DOCS_TMP to JULIA_DOCS
    for file in readdir(JULIA_DOCS_TMP)
        endswith(file, ".pdf") || continue
        from = joinpath(JULIA_DOCS_TMP, file)
        @debug "Copying a PDF" file from pwd()
        cp(from, file; force = true)
    end

    mktemp() do keyfile, iokey; mktemp() do sshconfig, iossh
        # Set up keyfile
        write(iokey, base64decode(get(ENV, "DOCUMENTER_KEY_PDF", "")))
        close(iokey)
        chmod(keyfile, 0o600)
        # Set up ssh config file
        print(iossh,
            """
            Host github.com
               StrictHostKeyChecking no
               HostName github.com
               IdentityFile $keyfile
               BatchMode yes
            """)
        close(iossh)
        chmod(sshconfig, 0o600)
        # Configure git
        run(`git config user.name "docs.julialang.org"`)
        run(`git config user.email "documenter@juliadocs.github.io"`)
        run(`git remote set-url origin git@github.com:JuliaLang/docs.julialang.org.git`)
        run(`git config core.sshCommand "ssh -F $(sshconfig)"`)
        # Committing all .pdf files
        run(`git add '*.pdf'`)
        run(`git commit --amend --date=now -m "PDF versions of Julia's manual."`)
        # Push
        run(`git push -f origin assets`)
    end end
end

function main()
    if "releases" in ARGS
        @info "building PDFs for all applicable Julia releases."
        foreach(build_release_pdf, collect_versions())
    elseif "build" in ARGS
        # Build a single version (used by parallel CI jobs with shallow clones)
        idx = findfirst(==("build"), ARGS)
        idx < length(ARGS) || error("usage: make.jl build <version|nightly>")
        target = ARGS[idx + 1]
        if target == "nightly"
            build_nightly_pdf()
        else
            build_release_pdf(VersionNumber(target); skip_existing=false, checkout=false)
        end
    elseif "nightly" in ARGS
        @info "building PDF for Julia nightly."
        build_nightly_pdf()
    elseif "commit" in ARGS
        @info "deploying to JuliaLang/docs.julialang.org"
        cd(() -> commit(), JULIA_DOCS)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
