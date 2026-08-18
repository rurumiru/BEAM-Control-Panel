defmodule BeamPanel.Slug do
  @moduledoc "Slug generation shared by servers, groups and projects."

  import Ecto.Changeset

  @doc "Derives `:slug` from `source` unless one was supplied explicitly."
  def put_slug(changeset, source, target \\ :slug) do
    case get_field(changeset, target) do
      value when is_binary(value) and value != "" ->
        put_change(changeset, target, slugify(value))

      _ ->
        case get_field(changeset, source) do
          nil -> changeset
          value -> put_change(changeset, target, slugify(value))
        end
    end
  end

  @doc """
  Converts arbitrary text (including Cyrillic) into a lowercase, dash-separated
  identifier that is safe for URLs, systemd unit names and file paths.
  """
  def slugify(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> transliterate()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "item-" <> (:crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower))
      slug -> String.slice(slug, 0, 60)
    end
  end

  @translit %{
    "а" => "a",
    "б" => "b",
    "в" => "v",
    "г" => "g",
    "д" => "d",
    "е" => "e",
    "ё" => "e",
    "ж" => "zh",
    "з" => "z",
    "и" => "i",
    "й" => "y",
    "к" => "k",
    "л" => "l",
    "м" => "m",
    "н" => "n",
    "о" => "o",
    "п" => "p",
    "р" => "r",
    "с" => "s",
    "т" => "t",
    "у" => "u",
    "ф" => "f",
    "х" => "h",
    "ц" => "c",
    "ч" => "ch",
    "ш" => "sh",
    "щ" => "sch",
    "ъ" => "",
    "ы" => "y",
    "ь" => "",
    "э" => "e",
    "ю" => "yu",
    "я" => "ya",
    "і" => "i",
    "ї" => "yi",
    "є" => "ye",
    "ґ" => "g"
  }

  defp transliterate(value) do
    value
    |> String.graphemes()
    |> Enum.map_join(&Map.get(@translit, &1, &1))
  end
end
