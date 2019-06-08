defmodule Cldr.DateTime.Formatter.Backend do
  @moduledoc false

  def define_date_time_formatter_module(config) do
    backend = config.backend
    config = Macro.escape(config)
    module = inspect(__MODULE__)

    quote location: :keep, bind_quoted: [config: config, backend: backend, module: module] do
      defmodule DateTime.Formatter do
        @moduledoc false
        if Cldr.Config.include_module_docs?(config.generate_docs) do
          @moduledoc """
          Implements the compilation and execution of
          date, time and datetime formats.

          """
        end

        alias Cldr.DateTime.Compiler
        alias Cldr.DateTime.Formatter

        @doc """
        Returns the formatted and localised date, time or datetime
        for a given `Date`, `Time`, `DateTime` or struct with the
        appropriate fields.

        ## Arguments

        * `date` is a `Date`, `Time`, `DateTime` or other struct that
        contains the required date and time fields.

        * `format` is a valid format string, for example `yy/MM/dd hh:MM`

        * `locale` is any valid locale name returned by `Cldr.known_locale_names/0`
          or a `Cldr.LanguageTag` struct. The default is `Cldr.get_current_locale/0`

        * `options` is a keyword list of options.  The valid options are:

        ## Options

        * `:number_system`.  The resulting formatted and localised date/time
        string will be transliterated into this number system. Number system
        is anything returned from `Cldr.Number.System.number_systems_for/1`

        *NOTE* This function is called by `Cldr.Date/to_string/2`, `Cldr.Time.to_string/2`
        and `Cldr.DateTime.to_string/2` which is the preferred API.

        ## Examples

            iex> Cldr.DateTime.Formatter.format %{year: 2017, month: 9, day: 3, hour: 10, minute: 23},
            ...> "yy/MM/dd hh:MM", "en"
            {:ok, "17/09/03 10:09"}

        """
        @spec format(
                Date.t() | Time.t() | DateTime.t(),
                String.t(),
                LanguageTag.t() | Locale.t(),
                Keyword.t()
              ) :: String.t()

        def format(date, format, locale \\ Cldr.get_locale(), options \\ [])

        # Insert generated functions for each locale and format here which
        # means that the lexing is done at compile time not runtime
        # which improves performance quite a bit.
        for format <- Cldr.DateTime.Format.format_list(config) do
          case Compiler.compile(format, backend, Cldr.DateTime.Formatter.Backend) do
            {:ok, transforms} ->
              def format(date, unquote(format) = f, locale, options) do
                number_system = if is_map(f), do: f[:number_system], else: options[:number_system]
                formatted = unquote(transforms)

                if error_list = format_errors(formatted) do
                  {:error, Enum.join(error_list, "; ")}
                else
                  formatted =
                    formatted
                    |> Enum.join()
                    |> transliterate(locale, number_system)

                  {:ok, formatted}
                end
              end

            {:error, message} ->
              raise Cldr.FormatCompileError,
                    "#{message} compiling date format: #{inspect(format)}"
          end
        end

        # This is the format function that is executed if the supplied format
        # has not otherwise been precompiled in the code above.  Since this function
        # has to tokenize, compile and then interpret the format string
        # there is a performance penalty.
        def format(date, format, locale, options) do
          case Compiler.tokenize(format) do
            {:ok, tokens, _} ->
              number_system =
                if is_map(format), do: format[:number_system], else: options[:number_system]

              formatted = apply_transforms(tokens, date, locale, options)

              if error_list = format_errors(formatted) do
                {:error, Enum.join(error_list, "; ")}
              else
                formatted =
                  formatted
                  |> Enum.join()
                  |> transliterate(locale, number_system)

                {:ok, formatted}
              end

            {:error, reason} ->
              {:error, reason}
          end
        end

        # Execute the transformation pipeline which does the
        # actual formatting
        defp apply_transforms(tokens, date, locale, options) do
          Enum.map(tokens, fn {token, _line, count} ->
            apply(Cldr.DateTime.Formatter, token, [date, count, locale, unquote(backend), options])
          end)
        end

        defp transliterate(formatted, _locale, nil) do
          formatted
        end

        defp transliterate(formatted, locale, number_system) do
          Cldr.Number.Transliterate.transliterate(formatted, locale, number_system, unquote(backend))
        end

        defp format_errors(list) do
          errors =
            list
            |> Enum.filter(fn
              {:error, _reason} -> true
              _ -> false
            end)
            |> Enum.map(fn {:error, reason} -> reason end)

          if Enum.empty?(errors), do: nil, else: errors
        end

        # Compile the formats used for timezones GMT format
        def gmt_tz_format(locale, offset, options \\ [])

        for locale_name <- Cldr.Config.known_locale_names(config) do
          {:ok, gmt_format} = Cldr.DateTime.Format.gmt_format(locale_name, backend)
          {:ok, gmt_zero_format} = Cldr.DateTime.Format.gmt_zero_format(locale_name, backend)
          {:ok, {pos_format, neg_format}} = Cldr.DateTime.Format.hour_format(locale_name, backend)
          {:ok, pos_transforms} = Compiler.compile(pos_format, backend, Cldr.DateTime.Formatter.Backend)
          {:ok, neg_transforms} = Compiler.compile(neg_format, backend, Cldr.DateTime.Formatter.Backend)

          def gmt_tz_format(
                %LanguageTag{cldr_locale_name: unquote(locale_name)},
                %{hour: 0, minute: 0},
                _options
              ) do
            unquote(gmt_zero_format)
          end

          def gmt_tz_format(
                %LanguageTag{cldr_locale_name: unquote(locale_name)} = locale,
                %{hour: hour, minute: _minute} = date,
                options
              )
              when hour >= 0 do
            unquote(pos_transforms)
            |> Cldr.DateTime.Format.gmt_format_type(options[:format] || :long)
            |> Cldr.Substitution.substitute(unquote(gmt_format))
            |> Enum.join()
          end

          def gmt_tz_format(
                %LanguageTag{cldr_locale_name: unquote(locale_name)} = locale,
                %{hour: _hour, minute: _minute} = date,
                options
              ) do
            unquote(neg_transforms)
            |> Cldr.DateTime.Format.gmt_format_type(options[:format] || :long)
            |> Cldr.Substitution.substitute(unquote(gmt_format))
            |> Enum.join()
          end
        end
      end
    end
  end
end