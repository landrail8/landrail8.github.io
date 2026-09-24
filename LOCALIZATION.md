# Редактирование, перевод и деплой сайта

Сайт публикуется в двух версиях:

- `https://landrail8.github.io/ru/` — русская версия и основной источник контента;
- `https://landrail8.github.io/en/` — английская версия, собранная из памяти переводов.

Адрес `https://landrail8.github.io/` перенаправляет посетителя на `/ru/`.

## 1. Редактирование русского контента

Рабочий файл русского контента:

```text
_data/locales/ru.yml
```

Редактируйте тексты только в этом файле. Английский файл `_data/locales/en.yml` генерируется автоматически.

У элементов списков есть поле `id`. Сохраняйте существующие `id`, даже если меняете текст или порядок элементов. Для нового результата, проекта или компетенции задавайте новый уникальный `id`.

Пример:

```yml
transformation_cases:
  items:
    - id: new-project
      title: Новый проект автоматизации
      challenge: Какую проблему бизнеса нужно было решить.
      role: За что я отвечал в проекте.
      solution: Какое решение было реализовано.
      result: Как изменился процесс или показатель бизнеса.
```

## 2. Проверка состояния перевода

Из корня репозитория выполните:

```bash
cd /Users/shur/dev/CV/landrail8.github.io
ruby scripts/translate.rb --check
```

Если все русские блоки уже переведены, команда завершится успешно и не обратится к API.

Если появились новые или изменённые блоки, команда перечислит их и завершится с ошибкой. Тогда нужно обновить английскую версию.

## 3. Локальный перевод новых блоков

Передайте ключ OpenAI через переменную окружения и запустите переводчик:

```bash
export OPENAI_API_KEY="ваш-ключ"
ruby scripts/translate.rb
unset OPENAI_API_KEY
```

При необходимости можно выбрать другую модель:

```bash
export OPENAI_API_KEY="ваш-ключ"
export OPENAI_TRANSLATION_MODEL="gpt-6-astra"
ruby scripts/translate.rb
unset OPENAI_API_KEY OPENAI_TRANSLATION_MODEL
```

Переводчик обновляет два файла:

- `_data/locales/en.yml` — готовый английский контент для сайта;
- `.translation-memory/en.yml` — память переводов с исходным текстом, хэшем, переводом и статусом.

Новый перевод получает статус `machine`. Неизменённые блоки со статусом `machine` или `approved` повторно в API не отправляются. Одинаковый русский текст также переиспользуется в разных элементах.

## 4. Проверка и утверждение перевода

Проверяйте и исправляйте машинный перевод в файле:

```text
.translation-memory/en.yml
```

Пример записи:

```yml
career-profile.title:
  source_hash: 0123456789abcdef
  source: Профессиональный профиль
  translation: Career Profile
  status: machine
```

После проверки исправьте `translation`, если это необходимо, и поменяйте статус:

```yml
status: approved
```

Если вы переводите изменённый блок вручную без обращения к API, также скопируйте в поле `source` актуальный русский текст из `_data/locales/ru.yml`. Поле `source_hash` менять вручную не нужно: скрипт пересчитает его, когда `source` полностью совпадает с русским источником и статус равен `approved`.

Обратите внимание, что `meta.title` и `sidebar.tagline` — отдельные блоки. При изменении должности обычно нужно проверить оба перевода.

Затем пересоберите английский файл:

```bash
ruby scripts/translate.rb
```

Чтобы утвердить все текущие машинные переводы одной командой:

```bash
ruby scripts/translate.rb --approve-all
```

Используйте эту команду только после проверки всех записей со статусом `machine`.

## 5. Локальный просмотр сайта

Для запуска Jekyll в Docker выполните:

```bash
cd /Users/shur/dev/CV/landrail8.github.io

docker run --rm -it \
  -p 4000:4000 \
  -v "$PWD":/srv/jekyll \
  -w /srv/jekyll \
  jekyll/jekyll:3.8 \
  jekyll serve --host 0.0.0.0
```

Откройте в браузере:

- `http://localhost:4000/ru/`;
- `http://localhost:4000/en/`.

Jekyll следит за изменениями и пересобирает страницы. Для остановки сервера нажмите `Ctrl+C`.

## 6. Проверка перед коммитом

Выполните:

```bash
ruby scripts/translate.rb --check
git diff --check
git status
```

Убедитесь, что обе локальные страницы открываются, английский перевод проверен, а команда `translate.rb --check` не сообщает о непереведённых блоках.

## 7. Коммит и деплой

После проверки:

```bash
git add .
git commit -m "Update site content"
git push origin master
```

Workflow `.github/workflows/deploy.yml` проверит перевод, соберёт Jekyll-сайт и задеплоит его в GitHub Pages.

Если локальный перевод уже сохранён, при деплое API повторно вызываться не будет. Если в коммит попал новый русский блок без английского перевода, workflow переведёт его и сохранит обновлённую память переводов.

## 8. Первоначальная настройка GitHub

Перед первым автоматическим деплоем:

1. Откройте `Settings → Pages → Build and deployment`.
2. В поле `Source` выберите `GitHub Actions`.
3. Откройте `Settings → Secrets and variables → Actions`.
4. Создайте repository secret с именем `OPENAI_API_KEY`.
5. При необходимости создайте repository variable `OPENAI_TRANSLATION_MODEL`. Если переменная отсутствует, используется `gpt-6-astra`.

Не сохраняйте ключ OpenAI в YAML, Markdown, `.env` под контролем Git или в исходном коде.
