using Base64

const BUILDROOT    = get(ENV, "BUILDROOT", pwd())
const JULIA_SOURCE = get(ENV, "JULIA_SOURCE", "$(BUILDROOT)/julia")
const JULIA_DOCS   = get(ENV, "JULIA_DOCS", "$(BUILDROOT)/docs.julialang.org")

# download and extract binary for a given version, return path to executable
function download_release(v::VersionNumber)
    x, y, z = v.major, v.minor, v.patch
    julia_exec = cd(BUILDROOT) do
        julia = "julia-$(x).$(y).$(z)-linux-x86_64"
        tarball = "$(julia).tar.gz"
        sha256 = "julia-$(x).$(y).$(z).sha256"
        @show julia
        @show tarball
        @show sha256
        println("---- SHA256 ----"); println(read(sha256, String)); println("---- SHA256 ----");
        run(`curl -o $(tarball) -L https://julialang-s3.julialang.org/bin/linux/x64/$(x).$(y)/$(tarball)`)
        run(`curl -o $(sha256) -L https://julialang-s3.julialang.org/bin/checksums/$(sha256)`)
        run(pipeline(`grep $(tarball) $(sha256)`, `sha256sum -c`))
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
        run(`curl -o $(tarball) -L https://julialangnightlies-s3.julialang.org/bin/linux/x64/$(tarball)`)
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
    @sync begin
        builder = @async begin
            withenv("TRAVIS_REPO_SLUG" => nothing, # workaround Documenter bugs and julia#26314
                    "BUILDROOT" => nothing) do
                run(`make -C $(JULIA_SOURCE)/doc pdf texplatform=docker JULIA_EXECUTABLE=$(julia_exec)`)
            end
        end
        @async begin
            while !istaskdone(builder)
                sleep(60)
                @info "building pdf ..."
            end
        end
    end
end

function copydocs(path)
    output = "$(JULIA_SOURCE)/doc/_build/pdf/en"
    for f in readdir(output)
        if startswith(f, "TheJuliaLanguage") && endswith(f, ".pdf")
            cp("$(output)/$(f)", path; force=true)
            @info "finished, output file copied to $(path)."
            break
        end
    end
end

function build_release_pdf(v::VersionNumber)
    x, y, z = v.major, v.minor, v.patch
    @info "building PDF for Julia v$(x).$(y).$(z)."

    file = "julia-$(x).$(y).$(z).pdf"
    path = "$(JULIA_DOCS)/$(file)"

    # early return if file exists
    if isfile(path)
        @info "PDF for Julia v$(x).$(y).$(z) already exists, skipping."
        return
    end

    # download julia binary
    @info "downloading release tarball."
    julia_exec = download_release(v)

    # checkout relevant tag and clean repo
    run(`git -C $(JULIA_SOURCE) checkout v$(x).$(y).$(z)`)
    run(`git -C $(JULIA_SOURCE) clean -fdx`)

    # invoke makedocs
    makedocs(julia_exec)

    # copy built PDF to JULIA_DOCS
    copydocs(path)
end

function build_nightly_pdf()
    @info "downloading nightly tarball"
    julia_exec, commit = download_nightly()
    # output is "julia version 1.1.0-DEV"
    _, _, v = split(readchomp(`$(julia_exec) --version`))
    @info "commit determined to $(commit) and version determined to $(v)."

    file = "julia-$(v).pdf"
    path = "$JULIA_DOCS/$file"

    # checkout correct commit and clean repo
    run(`git -C $(JULIA_SOURCE) checkout $(commit)`)
    run(`git -C $(JULIA_SOURCE) clean -fdx`)

    # invoke makedocs
    makedocs(julia_exec)

    # copy the built PDF to JULIA_DOCS
    copydocs(path)
end

# find all tags in the julia repo
function collect_versions()
    str = read(`git -C $(JULIA_SOURCE) ls-remote --tags origin`, String)
    versions = VersionNumber[]
    for line in eachline(IOBuffer(str))
        # lines are in the form 'COMMITSHA\trefs/tags/TAG'
        _, ref = split(line, '\t')
        _, _, tag = split(ref, '/')
        if occursin(r"^v\d+\.\d+\.\d+$", tag)
            # the version regex is not as general as Base.VERSION_REGEX -- we only build "pure"
            # versions and exclude tags that are pre-releases or have build information.
            v = VersionNumber(tag)
            # pdf doc only possible for 1.0.3 and above
            v >= v"1.0.4" && push!(versions, v)
        end
    end
    return versions
end

function withfile(f, file, contents)
    hasfile = isfile(file)
    original = hasfile ? read(file) : nothing
    write(file, contents)
    try
        f()
    finally
        hasfile ? write(file, original) : rm(file)
    end
end

# similar to Documenter.deploydocs
function commit()
    if get(ENV, "TRAVIS_PULL_REQUEST", "true") != "false"
        @info "skipping commit from pull requests."
        return
    end
    @info "committing built PDF files."

    # initialize git
    run(`git config user.name "zeptodoctor"`)
    run(`git config user.email "44736852+zeptodoctor@users.noreply.github.com"`)
    # committing all .pdf files
    run(`git add '*.pdf'`)
    run(`git commit --amend --date=now -m "PDF versions of Julia's manual."`)

    # setting up ssh key and force push
    keyfile = abspath(".documenter")
    try
        write(keyfile, String(base64decode(get(ENV, "DOCUMENTER_KEY_PDF", ""))))
        chmod(keyfile, 0o600)
        withfile("$(homedir())/.ssh/config",
            """
            Host github.com
               StrictHostKeyChecking no
               HostName github.com
               IdentityFile $keyfile
               BatchMode yes
            """) do
            run(`git remote set-url origin git@github.com:JuliaLang/docs.julialang.org.git`)
            run(`git push -f origin assets`)
        end
    finally
        rm(keyfile; force=true)
    end
end

function main()
    if "releases" in ARGS
        @info "building PDFs for all applicable Julia releases."
        foreach(build_release_pdf, collect_versions())
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
