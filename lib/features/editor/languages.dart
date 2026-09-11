import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/makefile.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';

final _byExt = <String, Mode>{
  'dart': langDart,
  'py': langPython,
  'js': langJavascript, 'mjs': langJavascript, 'cjs': langJavascript, 'jsx': langJavascript,
  'ts': langTypescript, 'tsx': langTypescript,
  'json': langJson,
  'yaml': langYaml, 'yml': langYaml,
  'sh': langBash, 'bash': langBash, 'zsh': langBash,
  'md': langMarkdown, 'markdown': langMarkdown,
  'go': langGo,
  'rs': langRust,
  'c': langC, 'h': langC,
  'cpp': langCpp, 'cc': langCpp, 'hpp': langCpp, 'cxx': langCpp,
  'java': langJava,
  'kt': langKotlin, 'kts': langKotlin,
  'swift': langSwift,
  'rb': langRuby,
  'php': langPhp,
  'html': langXml, 'htm': langXml, 'xml': langXml, 'svg': langXml, 'plist': langXml,
  'css': langCss,
  'sql': langSql,
  'ini': langIni, 'toml': langIni, 'cfg': langIni, 'conf': langIni,
};

final _byName = <String, Mode>{
  'dockerfile': langDockerfile,
  'makefile': langMakefile,
  'cmakelists.txt': langMakefile,
};

/// Highlight theme for a file name, or null for plain text.
CodeHighlightTheme? highlightThemeFor(String fileName) {
  final lower = fileName.toLowerCase();
  Mode? mode = _byName[lower];
  if (mode == null) {
    final dot = lower.lastIndexOf('.');
    if (dot >= 0) mode = _byExt[lower.substring(dot + 1)];
  }
  if (mode == null) return null;
  return CodeHighlightTheme(
    languages: {'lang': CodeHighlightThemeMode(mode: mode)},
    theme: atomOneDarkTheme,
  );
}
