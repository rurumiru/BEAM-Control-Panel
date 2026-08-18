defmodule BeamPanel.SlugTest do
  use ExUnit.Case, async: true

  alias BeamPanel.Slug

  describe "slugify/1" do
    test "lowercases and dashes ascii text" do
      assert Slug.slugify("My Phoenix App") == "my-phoenix-app"
    end

    test "transliterates Cyrillic" do
      assert Slug.slugify("Мой Проект") == "moy-proekt"
      assert Slug.slugify("Сервер Щёлково") == "server-schelkovo"
    end

    test "collapses punctuation and trims dashes" do
      assert Slug.slugify("  --Hello, World!!  ") == "hello-world"
    end

    test "never returns an empty slug" do
      slug = Slug.slugify("!!!")
      assert slug =~ ~r/^item-[0-9a-f]{6}$/
    end

    test "caps length at 60 characters" do
      assert String.length(Slug.slugify(String.duplicate("a", 120))) == 60
    end
  end
end
