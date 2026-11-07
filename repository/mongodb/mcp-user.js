const encode = encodeURIComponent;
const admin = connect(
  `mongodb://${encode(process.env.ROOT_USER)}:${encode(process.env.ROOT_PASSWORD)}@mongodb:27017/admin?authSource=admin`,
);
const user = process.env.MCP_USER;
const role = process.env.MCP_WRITE === "true" ? "readWriteAnyDatabase" : "readAnyDatabase";
const definition = { pwd: process.env.MCP_PASSWORD, roles: [{ role, db: "admin" }] };

if (admin.getUser(user)) {
  admin.updateUser(user, definition);
  print(`user ${user} updated: ${role}`);
} else {
  admin.createUser({ user, ...definition });
  print(`user ${user} created: ${role}`);
}
