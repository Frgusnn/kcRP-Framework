-- kcRP shared jobs
-- Definitions only: no SQL, no player mutation, no KCD:MP callbacks.

kcRP = kcRP or {}
kcRP.Shared = kcRP.Shared or {}

kcRP.Shared.Jobs = {
  unemployed = {
    label = "Sans emploi",
    defaultDuty = true,

    grades = {
      [0] = {
        name = "citizen",
        label = "Habitant",
        payment = 0,
        isBoss = false
      }
    }
  },

  blacksmith = {
    label = "Forgeron",
    defaultDuty = false,

    grades = {
      [0] = {
        name = "apprentice",
        label = "Apprenti forgeron",
        payment = 5,
        isBoss = false
      },

      [1] = {
        name = "journeyman",
        label = "Compagnon forgeron",
        payment = 10,
        isBoss = false
      },

      [2] = {
        name = "master",
        label = "Maître forgeron",
        payment = 20,
        isBoss = true
      }
    }
  },

  merchant = {
    label = "Marchand",
    defaultDuty = false,

    grades = {
      [0] = {
        name = "assistant",
        label = "Assistant marchand",
        payment = 5,
        isBoss = false
      },

      [1] = {
        name = "trader",
        label = "Marchand",
        payment = 10,
        isBoss = false
      },

      [2] = {
        name = "owner",
        label = "Propriétaire marchand",
        payment = 20,
        isBoss = true
      }
    }
  },

  guard = {
    label = "Garde",
    defaultDuty = false,

    grades = {
      [0] = {
        name = "recruit",
        label = "Recrue",
        payment = 6,
        isBoss = false
      },

      [1] = {
        name = "guard",
        label = "Garde",
        payment = 12,
        isBoss = false
      },

      [2] = {
        name = "captain",
        label = "Capitaine de la garde",
        payment = 25,
        isBoss = true
      }
    }
  },

  healer = {
    label = "Guérisseur",
    defaultDuty = false,

    grades = {
      [0] = {
        name = "apprentice",
        label = "Apprenti guérisseur",
        payment = 5,
        isBoss = false
      },

      [1] = {
        name = "healer",
        label = "Guérisseur",
        payment = 12,
        isBoss = false
      },

      [2] = {
        name = "master",
        label = "Maître guérisseur",
        payment = 20,
        isBoss = true
      }
    }
  }
}

Log("kcRP: shared jobs loaded (" .. tostring(#{
  "unemployed",
  "blacksmith",
  "merchant",
  "guard",
  "healer"
}) .. " jobs)")