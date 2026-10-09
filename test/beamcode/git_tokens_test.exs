defmodule Beamcode.GitTokensTest do
  use Beamcode.DataCase, async: true
  alias Beamcode.{Accounts, GitTokens, Projects}

  describe "parse_github/1" do
    test "reads owner/name from https, ssh and bare remotes" do
      for url <- [
            "https://github.com/AminoNordics/amino-monorepo",
            "https://github.com/AminoNordics/amino-monorepo.git",
            "https://x-access-token@github.com/AminoNordics/amino-monorepo.git",
            "git@github.com:AminoNordics/amino-monorepo.git",
            "ssh://git@github.com/AminoNordics/amino-monorepo.git",
            "github.com/AminoNordics/amino-monorepo/",
            "  https://github.com/AminoNordics/amino-monorepo\n"
          ] do
        assert GitTokens.parse_github(url) == {:ok, "AminoNordics/amino-monorepo"}, url
      end
    end

    test "rejects anything that isn't one github.com repo" do
      for url <- [
            nil,
            "",
            "/srv/repos/app",
            "https://gitlab.com/org/repo.git",
            "https://github.com/org",
            "https://github.com/org/repo/tree/main"
          ] do
        assert GitTokens.parse_github(url) == :error, inspect(url)
      end
    end
  end

  test "secret names are per project" do
    assert GitTokens.secret_name("amino-monorepo") == "GITHUB_TOKEN_AMINO_MONOREPO"
  end

  describe "merge/2" do
    test "adds a managed block and keeps other lines" do
      current = "# from chat\naksel/side github_pat_side\n"
      merged = GitTokens.merge(current, [{"org/app", "github_pat_app"}])

      assert merged =~
               ~r/\A# from chat\naksel\/side github_pat_side\n# beamcode: .*\norg\/app github_pat_app\n# beamcode: end\n\z/
    end

    test "replaces the block it wrote before and is stable" do
      once = GitTokens.merge("other x\n", [{"org/app", "old"}])
      twice = GitTokens.merge(once, [{"org/app", "new"}, {"org/lib", "lib"}])

      refute twice =~ "old"
      assert twice =~ "other x\n"
      assert twice =~ "org/app new\norg/lib lib\n"
      assert GitTokens.merge(twice, [{"org/app", "new"}, {"org/lib", "lib"}]) == twice
    end

    test "with no entries, removes the block and leaves the rest" do
      with_block = GitTokens.merge("other x\n", [{"org/app", "t"}])
      assert GitTokens.merge(with_block, []) == "other x\n"
      assert GitTokens.merge("", []) == ""
    end
  end

  test "projects record and validate their GitHub repo" do
    {:ok, user} = Accounts.create_user(%{"username" => "aksel", "password" => "password123"})

    {:ok, project} =
      Projects.insert_project(
        %{name: "app", kind: "code", directory: "/srv/app", github_repo: "org/app"},
        user
      )

    assert project.github_repo == "org/app"
    assert {:ok, ^project} = Projects.set_github_repo(project, "org/app")
    assert {:ok, %{github_repo: "org/other"}} = Projects.set_github_repo(project, "org/other")
    assert {:error, cs} = Projects.set_github_repo(project, "not a repo")
    assert %{github_repo: ["owner/name"]} = errors_on(cs)
  end
end
