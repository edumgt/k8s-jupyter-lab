# frozen_string_literal: true

require "json"

ROOT_PASSWORD = ENV.fetch("GITLAB_ROOT_PASSWORD", "CHANGE_ME")
DEMO_PASSWORD = ENV.fetch("GITLAB_DEMO_PASSWORD", "123456")
DEV1_TOKEN = ENV.fetch("DEV1_HTTP_TOKEN")
DEV2_TOKEN = ENV.fetch("DEV2_HTTP_TOKEN")
TOKEN_NAME = "codex-demo-http"
ORGANIZATION = Organizations::Organization.default_organization

def ensure_user(username:, email:, name:, password:, admin: false)
  user = User.find_by_username(username) || User.find_by_email(email) || User.new
  user.username = username
  user.email = email
  user.name = name
  user.admin = admin
  user.password = password
  user.password_confirmation = password
  user.skip_confirmation!
  user.assign_personal_namespace(ORGANIZATION) if user.namespace.nil?
  user.save!(validate: false)
  user
end

def ensure_public_project(user:, path:, description:)
  full_path = "#{user.namespace.full_path}/#{path}"
  project = Project.find_by_full_path(full_path)

  unless project
    project = Projects::CreateService.new(
      user,
      {
        name: path,
        path: path,
        namespace_id: user.namespace_id,
        visibility_level: Gitlab::VisibilityLevel::PUBLIC,
        initialize_with_readme: false,
        description: description,
      },
    ).execute
  end

  unless project&.persisted?
    message = project.respond_to?(:errors) ? project.errors.full_messages.join(", ") : "project creation failed"
    raise StandardError, message
  end

  project.update!(
    visibility_level: Gitlab::VisibilityLevel::PUBLIC,
    description: description,
  )
  project
end

def reset_http_token(user:, raw_token:)
  user.personal_access_tokens.where(name: TOKEN_NAME).destroy_all
  token = user.personal_access_tokens.build(
    name: TOKEN_NAME,
    scopes: %i[api read_repository write_repository],
    expires_at: 1.year.from_now,
  )
  token.set_token(raw_token)
  token.save!
end

root = ensure_user(
  username: "root",
  email: "root@example.com",
  name: "GitLab Root",
  password: ROOT_PASSWORD,
  admin: true,
)

dev1 = ensure_user(
  username: "dev1",
  email: "dev1@dev.com",
  name: "Dev One",
  password: DEMO_PASSWORD,
)

dev2 = ensure_user(
  username: "dev2",
  email: "dev2@dev.com",
  name: "Dev Two",
  password: DEMO_PASSWORD,
)

backend_project = ensure_public_project(
  user: dev1,
  path: "platform-backend",
  description: "Public backend app repo exported from platform-infra for the Kubernetes sandbox demo.",
)

frontend_project = ensure_public_project(
  user: dev2,
  path: "platform-frontend",
  description: "Public frontend app repo exported from platform-infra for the Kubernetes sandbox demo.",
)

reset_http_token(user: dev1, raw_token: DEV1_TOKEN)
reset_http_token(user: dev2, raw_token: DEV2_TOKEN)

puts(
  JSON.pretty_generate(
    {
      root: {
        username: root.username,
        email: root.email,
      },
      users: [
        {
          username: dev1.username,
          email: dev1.email,
          project: backend_project.full_path,
        },
        {
          username: dev2.username,
          email: dev2.email,
          project: frontend_project.full_path,
        },
      ],
    },
  ),
)
